#!/bin/bash
# Publishes a Lichess Desk release to the Homebrew tap (github.com/tdiethe/homebrew-tap):
# builds the app, uploads the zip as a GitHub release there, and updates Casks/lichess-desk.rb.
#
#   lichess-desk/release.sh 1.0.1
#
# Then anyone can:  brew tap tdiethe/tap && brew trust tdiethe/tap && brew install --cask lichess-desk
# Needs: gh (logged in with push access to the tap), Xcode command-line tools.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <version, e.g. 1.0.1>"; exit 1; }
TAP=tdiethe/homebrew-tap
TAG="lichess-desk-v$VERSION"
ZIP="build/Lichess-Desk-$VERSION.zip"

if gh release view "$TAG" -R "$TAP" >/dev/null 2>&1; then
  echo "$TAG already exists on $TAP; pick a new version"; exit 1
fi

VERSION="$VERSION" ./build.sh
rm -f "$ZIP"
ditto -c -k --keepParent "build/Lichess Desk.app" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SRC=$(git rev-parse --short HEAD)

gh release create "$TAG" "$ZIP" -R "$TAP" --title "Lichess Desk $VERSION" \
  --notes "Built from tdiethe/Chess-Stuff@$SRC. Install: \`brew install --cask tdiethe/tap/lichess-desk\`"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP" "$WORK/tap" -- -q
mkdir -p "$WORK/tap/Casks"
cat > "$WORK/tap/Casks/lichess-desk.rb" <<CASK
cask "lichess-desk" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$TAP/releases/download/lichess-desk-v#{version}/Lichess-Desk-#{version}.zip"
  name "Lichess Desk"
  desc "Unofficial lichess.org app made for streaming, with clock tint and auto-queen"
  homepage "https://github.com/tdiethe/Chess-Stuff"

  depends_on macos: :ventura

  app "Lichess Desk.app"

  zap trash: [
    "~/Library/Caches/local.hrstreamer.lichessdesk",
    "~/Library/HTTPStorages/local.hrstreamer.lichessdesk",
    "~/Library/Preferences/local.hrstreamer.lichessdesk.plist",
    "~/Library/Saved Application State/local.hrstreamer.lichessdesk.savedState",
    "~/Library/WebKit/local.hrstreamer.lichessdesk",
  ]

  caveats <<~EOS
    Lichess Desk isn't signed with an Apple Developer ID, so macOS blocks the first launch.
    Either open it once, then allow it in System Settings > Privacy & Security > Open Anyway,
    or run:
      xattr -dr com.apple.quarantine "#{appdir}/Lichess Desk.app"
  EOS
end
CASK
git -C "$WORK/tap" add Casks/lichess-desk.rb
git -C "$WORK/tap" commit -q -m "lichess-desk $VERSION"
git -C "$WORK/tap" push -q
echo "released $TAG  (sha256 $SHA)"
