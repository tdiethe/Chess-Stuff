"""
Game feeds for lichess and chess.com (public APIs, no login).

Each feed keeps today's finished games (since local midnight) and calls:
  on_start(ts)     a game started (lichess only; chess.com has no live feed)
  on_end(game)     a game finished that wasn't known before
  on_change()      today's record changed (scoreboard should refresh)
"""

import asyncio
import datetime as dt
import json
import random
import time
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path

UA = "hr-overlay/1.0 (OBS heart-rate overlay)"
BASELINE_PATH = Path(__file__).with_name("rating_baseline.json")
RECENT_GAMES = 10   # games shown in the recent-results widget


@dataclass
class Game:
    id: str
    site: str              # "lichess" | "chess.com"
    perf: str              # bullet / blitz / rapid / ...
    start: float           # unix seconds
    end: float
    result: str            # "win" | "loss" | "draw"
    opponent: str
    opp_rating: int | None
    rating: int | None     # my rating after the game
    rating_diff: int | None


def midnight() -> float:
    now = dt.datetime.now().astimezone()
    return now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def _get(url: str, accept: str = "application/json", etag: str | None = None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept})
    if etag:
        req.add_header("If-None-Match", etag)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.read().decode(), r.headers.get("ETag")
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return None, etag
        raise


# ---------------------------------------------------------------- scoreboard
class Tracker:
    """Today's games per site, and the scoreboard built from them."""

    def __init__(self, default_perf: str = "bullet"):
        self.games: dict[str, list[Game]] = {}
        self.current: dict[str, dict[str, int]] = {}     # site -> perf -> rating now
        self.baseline: dict[str, dict[str, int]] = {}    # site -> perf -> rating at start of day
        self.default_perf = default_perf
        self.last_site: str | None = None
        self.peaks: dict[str, int] = {}                  # game id -> heart-rate peak (filled by the bridge)

    def set_games(self, site: str, games: list[Game]) -> None:
        self.games[site] = sorted(games, key=lambda g: g.end)
        for g in self.games[site]:
            if g.rating is not None:
                self.current.setdefault(site, {})[g.perf] = g.rating

    def board(self) -> dict | None:
        everything = [g for gs in self.games.values() for g in gs]
        site = max(everything, key=lambda g: g.end).site if everything else self.last_site
        if site is None:
            return None
        games = self.games.get(site, [])
        perf = games[-1].perf if games else self.default_perf
        rating = self.current.get(site, {}).get(perf)
        base = self.baseline.get(site, {}).get(perf)
        streak = ""
        if games:
            r = games[-1].result
            n = 0
            for g in reversed(games):
                if g.result != r:
                    break
                n += 1
            streak = f"{r[0].upper()}{n}"
        # Longest win / loss runs today.
        best = {"win": 0, "loss": 0}
        run_r, run_n = None, 0
        for g in games:
            run_n = run_n + 1 if g.result == run_r else 1
            run_r = g.result
            if run_r in best:
                best[run_r] = max(best[run_r], run_n)
        recent = [{
            "id": g.id, "r": g.result[0].upper(), "diff": g.rating_diff,
            "opp": g.opponent, "opp_rating": g.opp_rating, "peak": self.peaks.get(g.id),
        } for g in games[-RECENT_GAMES:]]
        return {
            "site": site, "perf": perf, "rating": rating,
            "delta": rating - base if rating is not None and base is not None else None,
            "w": sum(g.result == "win" for g in games),
            "l": sum(g.result == "loss" for g in games),
            "d": sum(g.result == "draw" for g in games),
            "streak": streak,
            "best_w": best["win"], "best_l": best["loss"],
            "recent": recent,                            # oldest first
        }


# ---------------------------------------------------------------- lichess
def _lichess_game(j: dict, user: str) -> Game | None:
    if j.get("status") in ("created", "started"):
        return None
    me_white = (j["players"]["white"].get("user", {}).get("id") == user.lower())
    me = j["players"]["white" if me_white else "black"]
    opp = j["players"]["black" if me_white else "white"]
    winner = j.get("winner")
    result = "draw" if not winner else ("win" if (winner == "white") == me_white else "loss")
    diff = me.get("ratingDiff")
    return Game(
        id=j["id"], site="lichess", perf=j.get("perf") or j.get("speed", "?"),
        start=j["createdAt"] / 1000, end=j.get("lastMoveAt", j["createdAt"]) / 1000,
        result=result,
        opponent=opp.get("user", {}).get("name") or ("AI" if opp.get("aiLevel") else "anon"),
        opp_rating=opp.get("rating"),
        rating=(me["rating"] + diff) if me.get("rating") is not None and diff is not None else me.get("rating"),
        rating_diff=diff,
    )


async def lichess_feed(user: str, tracker: Tracker, on_start, on_end, on_change) -> None:
    seen: set[str] | None = None

    async def refresh() -> None:
        nonlocal seen
        since = int(midnight() * 1000)
        text, _ = await asyncio.to_thread(
            _get, f"https://lichess.org/api/games/user/{user}?since={since}&moves=false",
            "application/x-ndjson")
        games = [g for line in text.splitlines() if line.strip()
                 if (g := _lichess_game(json.loads(line), user))]
        tracker.set_games("lichess", games)
        # Rating at start of day = my pre-game rating in the first game today.
        base = tracker.baseline.setdefault("lichess", {})
        first: dict[str, int] = {}
        for g in tracker.games["lichess"]:
            if g.perf not in first and g.rating is not None and g.rating_diff is not None:
                first[g.perf] = g.rating - g.rating_diff
        base.update(first)
        if not games and "lichess" not in tracker.current:
            # No games yet today: show the current rating for the default perf.
            text, _ = await asyncio.to_thread(_get, f"https://lichess.org/api/user/{user}")
            perfs = json.loads(text).get("perfs", {})
            for p, v in perfs.items():
                if isinstance(v, dict) and "rating" in v:
                    tracker.current.setdefault("lichess", {})[p] = v["rating"]
                    base.setdefault(p, v["rating"])
        tracker.last_site = tracker.last_site or "lichess"
        new = [g for g in tracker.games["lichess"] if seen is not None and g.id not in seen]
        seen = {g.id for g in tracker.games["lichess"]}
        for g in new:
            on_end(g)
        on_change()

    async def wait_for_result(game_id: str) -> None:
        # The finished game can take a moment to show up in the games list.
        for _ in range(15):
            try:
                await refresh()
            except Exception as e:  # noqa: BLE001
                print(f"[lichess] fetch failed: {e}")
            if seen and game_id in seen:
                return
            await asyncio.sleep(2)

    # Watch the user's status every few seconds: a new playingId means a game
    # started; playing -> not playing (or a different id) means it finished.
    # (lichess's games-by-users stream sent nothing in testing, so we poll.)
    try:
        await refresh()
    except Exception as e:  # noqa: BLE001
        print(f"[lichess] fetch failed: {e}")
    current: str | None = None
    done: set[str] = set()          # games already reported as finished
    misses = 0                      # consecutive "not playing" answers for the current game
    first = True
    last_full = time.time()
    while True:
        try:
            text, _ = await asyncio.to_thread(
                _get, f"https://lichess.org/api/users/status?ids={user}&withGameIds=true")
            st = (json.loads(text) or [{}])[0]
            playing = st.get("playingId") if st.get("playing") else None
            # The status briefly reports "not playing" mid-game now and then, so a
            # game only counts as finished after two misses in a row (~6 s).
            if playing == current:
                misses = 0
            elif playing is None and current is not None:
                misses += 1
                if misses >= 2:
                    print(f"[lichess] game {current} finished")
                    done.add(current)
                    asyncio.ensure_future(wait_for_result(current))
                    current, misses = None, 0
            else:                                     # a different game id
                if current and current not in done:
                    print(f"[lichess] game {current} finished")
                    done.add(current)
                    asyncio.ensure_future(wait_for_result(current))
                if playing not in done and not first:
                    print(f"[lichess] game {playing} started")
                    on_start(time.time())
                current, misses = playing, 0
            first = False
            if time.time() - last_full > 60:      # slow safety-net refresh
                last_full = time.time()
                await refresh()
            await asyncio.sleep(3)
        except urllib.error.HTTPError as e:
            if e.code == 429:                     # rate-limited: lichess asks for a minute's pause
                print("[lichess] rate-limited; pausing 60 s")
                await asyncio.sleep(60)
            else:
                print(f"[lichess] status check failed: {e}")
                await asyncio.sleep(10)
        except Exception as e:  # noqa: BLE001
            print(f"[lichess] status check failed: {e}")
            await asyncio.sleep(10)


# ---------------------------------------------------------------- chess.com
CHESSCOM_DRAWS = {"agreed", "repetition", "stalemate", "insufficient", "50move",
                  "timevsinsufficient"}


def _chesscom_game(j: dict, user: str) -> Game | None:
    me_white = j["white"]["username"].lower() == user.lower()
    me, opp = (j["white"], j["black"]) if me_white else (j["black"], j["white"])
    res = me["result"]
    result = "win" if res == "win" else "draw" if res in CHESSCOM_DRAWS else "loss"
    start = None
    tags = {l[1:].split(" ", 1)[0]: l.split('"')[1] for l in j.get("pgn", "").splitlines()
            if l.startswith("[") and '"' in l}
    if "UTCDate" in tags and "UTCTime" in tags:
        try:
            start = dt.datetime.strptime(f'{tags["UTCDate"]} {tags["UTCTime"]}', "%Y.%m.%d %H:%M:%S") \
                .replace(tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            pass
    end = float(j["end_time"])
    if start is None or not (0 < end - start < 6 * 3600):
        start = end - 60
    return Game(
        id=j.get("uuid") or j["url"], site="chess.com", perf=j.get("time_class", "?"),
        start=start, end=end, result=result,
        opponent=opp["username"], opp_rating=opp.get("rating"),
        rating=me.get("rating"), rating_diff=None,
    )


def _load_baseline() -> dict:
    try:
        b = json.loads(BASELINE_PATH.read_text())
        return b if b.get("date") == dt.date.today().isoformat() else {}
    except (OSError, ValueError):
        return {}


def _save_baseline(perfs: dict) -> None:
    try:
        BASELINE_PATH.write_text(json.dumps({"date": dt.date.today().isoformat(), "chess.com": perfs}))
    except OSError:
        pass


async def chesscom_feed(user: str, tracker: Tracker, on_start, on_end, on_change) -> None:
    seen: set[str] | None = None
    etags: dict[str, str] = {}
    cache: dict[str, list] = {}
    base = tracker.baseline.setdefault("chess.com", {})
    base.update(_load_baseline().get("chess.com", {}))

    # Rating before today's first game, from the stats endpoint (chess.com
    # doesn't report per-game rating changes). Saved so restarts keep it.
    try:
        text, _ = await asyncio.to_thread(_get, f"https://api.chess.com/pub/player/{user}/stats")
        for k, v in json.loads(text).items():
            if k.startswith("chess_") and isinstance(v, dict) and "last" in v:
                perf = k.removeprefix("chess_")
                tracker.current.setdefault("chess.com", {})[perf] = v["last"]["rating"]
                base.setdefault(perf, v["last"]["rating"])
    except Exception as e:  # noqa: BLE001
        print(f"[chess.com] stats fetch failed: {e}")
    tracker.last_site = tracker.last_site or "chess.com"

    while True:
        try:
            m0 = midnight()
            months = {dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y/%m")
                      for t in (m0, time.time())}
            raw = []
            for m in sorted(months):
                url = f"https://api.chess.com/pub/player/{user}/games/{m}"
                text, etag = await asyncio.to_thread(_get, url, "application/json", etags.get(url))
                if text is not None:
                    cache[url] = json.loads(text).get("games", [])
                    etags[url] = etag
                raw += cache.get(url, [])
            games = [g for j in raw if j.get("rules") == "chess" and j.get("end_time", 0) >= m0
                     if (g := _chesscom_game(j, user))]
            games.sort(key=lambda g: g.end)
            # Fill rating_diff from the previous game of the same perf (or the baseline).
            prev: dict[str, int] = {}
            for g in games:
                before = prev.get(g.perf, base.get(g.perf))
                if g.rating is not None and before is not None:
                    g.rating_diff = g.rating - before
                if g.rating is not None:
                    prev[g.perf] = g.rating
                    base.setdefault(g.perf, g.rating)   # first sighting today, if stats failed
            _save_baseline(base)
            tracker.set_games("chess.com", games)
            new = [g for g in games if seen is not None and g.id not in seen]
            seen = {g.id for g in games}
            for g in new:
                on_end(g)
            on_change()
        except Exception as e:  # noqa: BLE001
            print(f"[chess.com] fetch failed: {e}")
        await asyncio.sleep(15)


# ---------------------------------------------------------------- demo
async def demo_feed(tracker: Tracker, on_start, on_end, on_change, cycle: float = 50) -> None:
    """Fake bullet games lined up with the demo heart rate (game from 5 s to 45 s of each cycle)."""
    games: list[Game] = []
    rating = 1573
    tracker.current["lichess"] = {"bullet": rating}
    tracker.baseline["lichess"] = {"bullet": rating}
    tracker.last_site = "lichess"
    on_change()
    t0 = time.time()
    n = 0
    while True:
        cyc = t0 + n * cycle
        await asyncio.sleep(max(0, cyc + 5 - time.time()))
        start = time.time()
        on_start(start)
        await asyncio.sleep(max(0, cyc + 45 - time.time()))
        result = random.choice(["win", "win", "loss", "draw"])
        diff = {"win": 8, "loss": -8, "draw": 0}[result] + random.randint(-2, 2) * (result != "draw")
        rating += diff
        g = Game(id=f"demo{n}", site="lichess", perf="bullet", start=start, end=time.time(),
                 result=result, opponent=random.choice(["yazan1345", "athi", "BHZChessManiac05"]),
                 opp_rating=random.randint(1540, 1640), rating=rating, rating_diff=diff)
        games.append(g)
        tracker.set_games("lichess", games)
        on_end(g)
        on_change()
        n += 1
