#!/bin/bash
# Publishes a signed, notarised Lichess Desk release to the Homebrew tap
# (github.com/tdiethe/homebrew-tap): builds the app, signs it with your Developer ID,
# has Apple notarise it, uploads the zip as a GitHub release and updates Casks/lichess-desk.rb.
#
#   lichess-desk/release.sh 1.0.1
#
# Then anyone can:  brew tap tdiethe/tap && brew trust tdiethe/tap && brew install --cask lichess-desk
#
# One-time setup (see README):
#   - a "Developer ID Application" certificate in your keychain (Xcode > Settings > Accounts)
#   - notary credentials:  xcrun notarytool store-credentials lichess-desk --apple-id <you> --team-id <TEAM>
# Also needs gh (with push access to the tap) and the Xcode command-line tools.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <version, e.g. 1.0.1>"; exit 1; }
TAP=tdiethe/homebrew-tap
TAG="lichess-desk-v$VERSION"
APP="build/Lichess Desk.app"
ZIP="build/Lichess-Desk-$VERSION.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-lichess-desk}"

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
[[ -n "$SIGN_ID" ]] || { echo "No 'Developer ID Application' certificate in your keychain (see the setup notes at the top)."; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "No notary credentials saved as '$NOTARY_PROFILE' (see the setup notes at the top)."; exit 1; }
if gh release view "$TAG" -R "$TAP" >/dev/null 2>&1; then
  echo "$TAG already exists on $TAP; pick a new version"; exit 1
fi

echo "signing as: $SIGN_ID"
VERSION="$VERSION" SIGN_ID="$SIGN_ID" ./build.sh
codesign --verify --strict --verbose=1 "$APP"

echo "notarising (usually a minute or two)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
echo "$OUT"
if ! grep -q '"status":"Accepted"' <<<"$OUT"; then
  ID=$(sed -E 's/.*"id":"([^"]+)".*/\1/' <<<"$OUT")
  xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" || true
  echo "notarisation failed"; exit 1
fi
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"   # Gatekeeper's verdict, as a downloader would get it

# Re-zip so the download carries the stapled ticket (works offline on first launch).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SRC=$(git rev-parse --short HEAD)

gh release create "$TAG" "$ZIP" -R "$TAP" --title "Lichess Desk $VERSION" \
  --notes "Signed and notarised. Built from tdiethe/Chess-Stuff@$SRC. Install: \`brew install --cask tdiethe/tap/lichess-desk\`"

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
end
CASK
git -C "$WORK/tap" add Casks/lichess-desk.rb
git -C "$WORK/tap" commit -q -m "lichess-desk $VERSION"
git -C "$WORK/tap" push -q
echo "released $TAG  (sha256 $SHA)"
