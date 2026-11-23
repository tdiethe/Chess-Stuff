# /// script
# requires-python = ">=3.11"
# dependencies = ["bleak>=0.22"]
# ///
"""
BLE heart-rate -> OBS overlay bridge, with lichess / chess.com game tracking.

Connects to any device broadcasting the standard BLE Heart Rate Service
(e.g. a Garmin Fenix with "Broadcast Heart Rate" on) and serves, always on
port 8765 (an older copy still running there is shut down automatically):

  http://127.0.0.1:8765/          transparent overlay page (OBS Browser Source)
  http://127.0.0.1:8765/events    Server-Sent Events stream of readings
  http://127.0.0.1:8765/hr.txt    current bpm as plain text
  http://127.0.0.1:8765/newgame   start a new game by hand (resets the game peak)

With --lichess / --chesscom it follows your games: today's record and rating
change on the scoreboard, a post-game heart-rate card after each game, and
games are detected automatically (Enter in this terminal still works too).

Zones (names, bpm ranges, colours) live in zones.toml; edits apply live.

Run:   uv run hr-overlay/hr_overlay.py --name fenix --lichess tommydacat
       uv run hr-overlay/hr_overlay.py --name fenix --chesscom tommydacat
       uv run hr-overlay/hr_overlay.py --name fenix --lichess tommydacat --chesscom tommydacat
       uv run hr_overlay.py --demo          (fake heart rate and games, no Bluetooth)
"""

import argparse
import asyncio
import errno
import json
import math
import random
import sys
import time
import tomllib
import urllib.request
from collections import deque
from dataclasses import asdict
from pathlib import Path

import chess_feed

HR_SERVICE = "0000180d-0000-1000-8000-00805f9b34fb"
HR_MEASUREMENT = "00002a37-0000-1000-8000-00805f9b34fb"

PORT = 8765
HISTORY_SECONDS = 300   # trace length shown under the number
CARD_SECONDS = 15       # how long the post-game card stays up

state = {
    "bpm": None, "ts": 0.0, "device": None, "status": "starting",
    "peak": None,            # highest bpm since the last new game
    "zones": None,           # from zones.toml: {"zones": [...], "spike": n, "card_zone": name}
    "board": None,           # scoreboard (today's record)
    "card": None,            # last post-game card
}
listeners: set[asyncio.Queue] = set()
history: deque[tuple[float, int]] = deque()                 # last HISTORY_SECONDS of readings
session: deque[tuple[float, int]] = deque(maxlen=6 * 3600)  # ~6 h of readings
game_starts: deque[float] = deque()                          # game-start markers on the trace
tracker = chess_feed.Tracker()
shutdown = asyncio.Event()
TXT_PATH = Path(__file__).with_name("hr.txt")


def snapshot(with_history: bool = False) -> str:
    msg = {
        "bpm": state["bpm"], "ts": round(state["ts"] * 1000),
        "status": state["status"], "device": state["device"],
        "peak": state["peak"], "zones": state["zones"],
        "games": [round(t * 1000) for t in game_starts],
        "board": state["board"], "card": state["card"],
    }
    if with_history:
        msg["history"] = [[round(t * 1000), b] for t, b in history]
    return json.dumps(msg)


def broadcast() -> None:
    msg = snapshot()
    for q in list(listeners):
        q.put_nowait(msg)


ZONES_PATH = Path(__file__).with_name("zones.toml")


def load_zones() -> dict:
    with open(ZONES_PATH, "rb") as f:
        cfg = tomllib.load(f)
    zones = sorted(
        ({"name": str(z["name"]), "from": int(z["from"]), "color": str(z.get("color", "#ffffff"))}
         for z in cfg["zone"]),
        key=lambda z: z["from"])
    if not zones:
        raise ValueError("no [[zone]] entries")
    card_zone = cfg.get("card_zone", zones[-1]["name"])
    if card_zone not in [z["name"] for z in zones]:
        raise ValueError(f"card_zone {card_zone!r} isn't one of the zone names")
    return {"zones": zones, "spike": int(cfg.get("spike", 15)), "card_zone": card_zone}


async def watch_zones() -> None:
    """Reload zones.toml whenever it changes; keep the old zones if the new file is broken."""
    mtime = None
    while True:
        try:
            m = ZONES_PATH.stat().st_mtime
            if m != mtime:
                mtime = m
                state["zones"] = load_zones()
                print("[hr] zones: " + ", ".join(f"{z['name']} {z['from']}+" for z in state["zones"]["zones"]))
                broadcast()
        except Exception as e:  # noqa: BLE001
            print(f"[hr] zones.toml not loaded ({e}); keeping previous zones")
        await asyncio.sleep(2)


def publish(bpm: int | None = None, status: str | None = None) -> None:
    if bpm is not None:
        now = time.time()
        state["bpm"], state["ts"] = bpm, now
        state["peak"] = bpm if state["peak"] is None else max(state["peak"], bpm)
        history.append((now, bpm))
        session.append((now, bpm))
        while history and history[0][0] < now - HISTORY_SECONDS:
            history.popleft()
        while game_starts and game_starts[0] < now - HISTORY_SECONDS:
            game_starts.popleft()
        try:
            TXT_PATH.write_text(f"{bpm}")
        except OSError:
            pass
    if status is not None:
        state["status"] = status
        print(f"[hr] {status}")
    broadcast()


def new_game(at: float | None = None, mark: bool = True, quiet: bool = False) -> None:
    at = at or time.time()
    state["peak"] = state["bpm"]
    if mark and all(abs(at - t) > 10 for t in game_starts):
        items = sorted([*game_starts, at])
        game_starts.clear()
        game_starts.extend(items)
    if not quiet:
        print("[hr] new game — peak reset")
    broadcast()


def game_card(g: chess_feed.Game) -> dict:
    """Heart-rate stats for the game's time window."""
    readings = [(t, b) for t, b in session if g.start <= t <= g.end + 2]
    card = asdict(g) | {"at": round(time.time() * 1000), "avg": None, "peak": None, "panic_s": 0}
    if readings:
        vals = [b for _, b in readings]
        card["avg"] = round(sum(vals) / len(vals))
        card["peak"] = max(vals)
        cfg = state["zones"]
        if cfg:
            limit = next(z["from"] for z in cfg["zones"] if z["name"] == cfg["card_zone"])
            card["panic_label"] = cfg["card_zone"]
            card["panic_s"] = round(sum(
                min(t2 - t1, 5) for (t1, b1), (t2, _) in zip(readings, readings[1:]) if b1 >= limit))
    return card


def on_game_start(at: float) -> None:
    new_game(at)


def on_game_end(g: chess_feed.Game) -> None:
    state["card"] = game_card(g)
    c = state["card"]
    if c["peak"] is not None:
        tracker.peaks[g.id] = c["peak"]
    print(f"[game] {g.site}: {g.result} vs {g.opponent} — avg {c['avg']}, peak {c['peak']}, "
          f"{c['panic_s']}s in {c.get('panic_label', 'top zone')}")
    # Mark where the game began (covers chess.com, which has no live start event),
    # and start the next game's peak from here.
    new_game(at=g.start, quiet=True)


def on_board_change() -> None:
    # Heart-rate peak for any of today's games we have readings for (shown on the
    # recent-games tiles); games played before the bridge started have none.
    for games in tracker.games.values():
        for g in games:
            if g.id not in tracker.peaks:
                vals = [b for t, b in session if g.start <= t <= g.end + 2]
                if vals:
                    tracker.peaks[g.id] = max(vals)
    state["board"] = tracker.board()
    broadcast()


def parse_hr(data: bytearray) -> int:
    flags = data[0]
    return int.from_bytes(data[1:3], "little") if flags & 0x01 else data[1]


# ---------------------------------------------------------------- BLE side
async def ble_loop(name_filter: str | None) -> None:
    from bleak import BleakClient, BleakScanner

    while True:
        publish(status="scanning for heart-rate broadcasters…")

        def match(d, adv):
            name = (d.name or adv.local_name or "").lower()
            if name_filter:
                # Match by name alone: some watches don't list the HR service
                # in their advertisement; we check it after connecting.
                return name_filter.lower() in name
            return HR_SERVICE in [u.lower() for u in adv.service_uuids]

        device = await BleakScanner.find_device_by_filter(match, timeout=15.0)
        if device is None:
            publish(status="no HR broadcaster found — is Broadcast Heart Rate on? retrying")
            await asyncio.sleep(2)
            continue

        state["device"] = device.name or device.address
        disconnected = asyncio.Event()
        try:
            async with BleakClient(device, disconnected_callback=lambda _: disconnected.set()) as client:
                publish(status=f"connected to {state['device']}")
                await client.start_notify(HR_MEASUREMENT, lambda _, d: publish(bpm=parse_hr(d)))
                await disconnected.wait()
        except Exception as e:  # noqa: BLE001
            publish(status=f"connection error: {e}")
        publish(status="disconnected, reconnecting")
        await asyncio.sleep(2)


async def scan_list() -> None:
    from bleak import BleakScanner

    print("[hr] scanning 15 s — every device seen, strongest signal first:")
    found = await BleakScanner.discover(timeout=15.0, return_adv=True)
    for d, adv in sorted(found.values(), key=lambda v: -v[1].rssi):
        name = d.name or adv.local_name or "(no name)"
        hr = "  <-- HEART RATE" if HR_SERVICE in [u.lower() for u in adv.service_uuids] else ""
        print(f"  {adv.rssi:>4} dBm  {name:28}  {d.address}{hr}")
    print(f"[hr] {len(found)} devices. Use --name <part of name> to pick one.")


async def demo_loop() -> None:
    # Calm baseline with a time-scramble spike every ~50 s.
    state["device"] = "demo"
    publish(status="demo mode")
    t0 = time.time()
    while True:
        t = (time.time() - t0) % 50
        spike = 45 * math.exp(-((t - 30) / 6) ** 2)
        publish(bpm=int(66 + 4 * math.sin(t / 5) + spike + random.randint(-1, 1)))
        await asyncio.sleep(1)


async def stdin_loop() -> None:
    if not sys.stdin.isatty():
        return
    print("[hr] press Enter here to start a new game by hand (resets PEAK)")
    while True:
        line = await asyncio.to_thread(sys.stdin.readline)
        if not line:
            return
        new_game()


# ---------------------------------------------------------------- HTTP side
OVERLAY = Path(__file__).with_name("overlay.html")
WHOAMI = b"hr-overlay"


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        request = await reader.readline()
        while (await reader.readline()) not in (b"\r\n", b"\n", b""):
            pass
        path = request.split(b" ")[1].decode() if b" " in request else "/"
        path = path.split("?")[0]

        if path == "/events":
            writer.write(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                b"Cache-Control: no-cache\r\nConnection: keep-alive\r\n"
                b"Access-Control-Allow-Origin: *\r\n\r\n"
            )
            q: asyncio.Queue = asyncio.Queue()
            listeners.add(q)
            # First message carries the recent history so a reloaded overlay redraws the trace.
            q.put_nowait(snapshot(with_history=True))
            try:
                while True:
                    try:
                        msg = await asyncio.wait_for(q.get(), timeout=15)
                        writer.write(f"data: {msg}\n\n".encode())
                    except TimeoutError:
                        writer.write(b": ping\n\n")
                    await writer.drain()
            finally:
                listeners.discard(q)
            return

        if path == "/hr.txt":
            body, ctype = (str(state["bpm"] or "--")).encode(), "text/plain"
        elif path == "/newgame":
            new_game()
            body, ctype = b"new game started\n", "text/plain"
        elif path == "/whoami":
            body, ctype = WHOAMI, "text/plain"
        elif path == "/shutdown":
            # Only reachable from this machine (we bind 127.0.0.1); used by a
            # newly started copy to take over the port.
            body, ctype = b"bye\n", "text/plain"
            asyncio.get_running_loop().call_later(0.2, shutdown.set)
        elif path in ("/", "/index.html"):
            body, ctype = OVERLAY.read_bytes(), "text/html; charset=utf-8"
        else:
            writer.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            return
        writer.write(
            f"HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\nContent-Length: {len(body)}\r\n"
            "Cache-Control: no-cache\r\nConnection: close\r\n\r\n".encode() + body
        )
        await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


def _local_get(port: int, path: str) -> bytes | None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as r:
            return r.read()
    except Exception:  # noqa: BLE001
        return None


async def bind(port: int) -> asyncio.Server:
    """Always use the same port. If an older copy of this bridge holds it, ask it to quit."""
    try:
        return await asyncio.start_server(handle, "127.0.0.1", port)
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
    if await asyncio.to_thread(_local_get, port, "/whoami") == WHOAMI:
        print(f"[hr] another copy is running on port {port}; asking it to quit")
        await asyncio.to_thread(_local_get, port, "/shutdown")
    else:
        print(f"[hr] port {port} is busy. If it's an older copy of this script, stop it with Ctrl-C\n"
              f"     in its terminal, or run:  lsof -ti :{port} | xargs kill")
    for _ in range(50):
        await asyncio.sleep(0.2)
        try:
            return await asyncio.start_server(handle, "127.0.0.1", port)
        except OSError as e:
            if e.errno != errno.EADDRINUSE:
                raise
    sys.exit(f"[hr] port {port} still busy; not starting (OBS expects this port).")


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", help="only connect to a device whose name contains this text")
    ap.add_argument("--lichess", metavar="USER", help="follow this lichess user's games")
    ap.add_argument("--chesscom", metavar="USER", help="follow this chess.com user's games")
    ap.add_argument("--port", type=int, default=PORT, help=argparse.SUPPRESS)
    ap.add_argument("--demo", action="store_true", help="fake heart rate (and games), no Bluetooth")
    ap.add_argument("--scan", action="store_true", help="list nearby Bluetooth devices and exit")
    args = ap.parse_args()
    if args.scan:
        await scan_list()
        return
    try:
        state["zones"] = load_zones()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"[hr] couldn't read zones.toml: {e}")

    server = await bind(args.port)
    print(f"[hr] overlay: http://127.0.0.1:{args.port}/   (OBS Browser Source, 420 x 320)")

    tasks = [server.serve_forever(), demo_loop() if args.demo else ble_loop(args.name), stdin_loop(), watch_zones()]
    cb = (on_game_start, on_game_end, on_board_change)
    if args.lichess:
        tasks.append(chess_feed.lichess_feed(args.lichess, tracker, *cb))
    if args.chesscom:
        tasks.append(chess_feed.chesscom_feed(args.chesscom, tracker, *cb))
    if args.demo and not (args.lichess or args.chesscom):
        tasks.append(chess_feed.demo_feed(tracker, *cb))

    running = [asyncio.ensure_future(t) for t in tasks]
    stop = asyncio.ensure_future(shutdown.wait())
    # Run until the server or heart-rate loop dies, or a newer copy takes over.
    # (The Enter-key reader may finish early when there's no terminal; that's fine.)
    await asyncio.wait([stop, *running[:2]], return_when=asyncio.FIRST_COMPLETED)
    if shutdown.is_set():
        print("[hr] a newer copy took over the port; exiting")
    server.close()
    for t in running:
        t.cancel()
    await asyncio.gather(*running, return_exceptions=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
