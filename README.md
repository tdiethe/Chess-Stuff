# Chess Stuff

Random collection of scripts and other stuff, mostly for streaming bullet chess.

## Heart-rate overlay for OBS — `hr_overlay.py`

Reads heart rate from a watch that broadcasts over Bluetooth (e.g. Garmin Fenix with
*Broadcast Heart Rate* on) and serves an OBS Browser Source at `http://127.0.0.1:8765/`:

- big BPM with zone colour and label, spike flash, per-game peak
- 5-minute trace with game markers
- lichess / chess.com session scoreboard (rating change, W/L/D, streak)
- last 10 games as tiles (result, rating change, HR peak) plus best streaks
- post-game card: average, peak and time spent in the panic zone

```bash
uv run hr_overlay.py --name fenix --lichess <user>            # or --chesscom <user>, or both
uv run hr_overlay.py --demo                                    # fake data, no watch needed
uv run hr_overlay.py --scan                                    # list nearby BLE devices
```

Add a Browser Source in OBS pointing at `http://127.0.0.1:8765/`, size **420 × 320**.
The port never changes; starting a new copy takes over from an old one.
Zones live in `zones.toml` and reload live when you save it.
`http://127.0.0.1:8765/hr.txt` gives the plain number for a Text source.

## Lichess Desk — `mac_app/`

A small native Mac app around lichess.org, for streaming:

- full desktop site (right-drag arrows, premoves, keyboard moves), stays logged in
- fixed window title and size presets (View menu), so OBS Window Capture never needs redoing
- board tint and auto-queen built in, with settings in the **Tint** and **Play** menus
- Auto-queen button under your clock; hold ⌥ while promoting to pick another piece

```bash
./build_app.sh            # builds build/Lichess Desk.app
./build_app.sh --install  # and copies it to ~/Applications
```

Needs the Xcode command-line tools (`swiftc`). Not affiliated with lichess.org.

## Userscripts (Tampermonkey)

- `clock-board-tint.js` — tints the board yellow → amber → orange → red as **your** clock
  runs down, pulses in the last seconds, fades after the game. Also has an optional
  auto-queen with an on-page button. Lichess and chess.com. Lichess Desk bundles this file.
- `auto-queen-toggle.js` — standalone auto-queen toggle (Alt+Q, hold Shift to choose).
  Don't run it alongside the auto-queen in `clock-board-tint.js`.
