#!/bin/bash
# Builds "Lichess Desk.app" into ./build. Pass --install to also copy it to ~/Applications.
# Re-run after editing clock-board-tint.js: the app bundles that file.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Lichess Desk.app"
TMP="build/tmp"
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP/AppIcon.iconset"

echo "compiling…"
swiftc -O -swift-version 5 -target arm64-apple-macos13.3 \
  mac_app/main.swift -o "$APP/Contents/MacOS/LichessDesk"

echo "icon…"
swiftc -swift-version 5 mac_app/make_icon.swift -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cp mac_app/Info.plist "$APP/Contents/"
cp clock-board-tint.js "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
rm -rf "$TMP"
echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Lichess Desk.app"
  cp -R "$APP" ~/Applications/
  echo "installed: ~/Applications/Lichess Desk.app"
fi
