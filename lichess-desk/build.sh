#!/bin/bash
# Builds "Lichess Desk.app" (universal) into lichess-desk/build. Pass --install to also copy it to ~/Applications.
# Re-run after editing ../userscripts/clock-board-tint.user.js: the app bundles that file.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Lichess Desk.app"
TMP="build/tmp"
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP/AppIcon.iconset"

echo "compiling…"
# Universal binary: Apple Silicon + Intel.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.3 main.swift -o "$TMP/LichessDesk-$arch"
done
lipo -create "$TMP/LichessDesk-arm64" "$TMP/LichessDesk-x86_64" -output "$APP/Contents/MacOS/LichessDesk"

echo "icon…"
swiftc -swift-version 5 make_icon.swift -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP/Contents/"
if [[ -n "${VERSION:-}" ]]; then   # set by release.sh
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
cp ../userscripts/clock-board-tint.user.js "$APP/Contents/Resources/clock-board-tint.js"
codesign --force --sign - "$APP"
rm -rf "$TMP"
echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Lichess Desk.app"
  cp -R "$APP" ~/Applications/
  echo "installed: ~/Applications/Lichess Desk.app"
fi
