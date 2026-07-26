#!/bin/bash
# Cut a release of Panewright's patched AeroSpace from this checkout.
#
#   ./panewright-release.sh pw.1
#
# Produces AeroSpace-v<base>-<suffix>.zip: the official upstream release
# asset with the two executables replaced by universal builds of this tree,
# re-signed and notarized under Will's Developer ID. Everything else in the
# zip — manpages, shell completions, legal — ships exactly as upstream built
# it, because the official zip is downloaded fresh as the template rather
# than trusting anything on this machine (the local install is itself
# patched, so it can't be the template).
#
# The base tag is read from git: this branch must be rebased onto the tag
# matching what the cask will call itself, or the CLI/server version
# handshake tells users lies.
set -euo pipefail
cd "$(dirname "$0")"

SUFFIX="${1:?usage: ./panewright-release.sh <suffix, e.g. pw.1>}"
BASE_TAG="$(git describe --tags --abbrev=0)"
PW_TAG="$BASE_TAG-$SUFFIX"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "no Developer ID identity"; exit 1; }

echo "== building universal binaries"
export PATH="/opt/homebrew/bin:$PATH"
./generate.sh --ignore-xcodeproj --ignore-cmd-help --build-version "${BASE_TAG#v}"
swift build -c release --arch arm64 --arch x86_64 --product AeroSpaceApp
swift build -c release --arch arm64 --arch x86_64 --product aerospace

echo "== fetching pristine upstream $BASE_TAG"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/upstream.zip" \
    "https://github.com/nikitabobko/AeroSpace/releases/download/$BASE_TAG/AeroSpace-$BASE_TAG.zip"
ditto -x -k "$WORK/upstream.zip" "$WORK"
ROOT="$WORK/AeroSpace-$BASE_TAG"
[ -d "$ROOT/AeroSpace.app" ] || { echo "unexpected zip layout"; exit 1; }

echo "== swapping executables"
cp .build/apple/Products/Release/AeroSpaceApp "$ROOT/AeroSpace.app/Contents/MacOS/AeroSpace"
cp .build/apple/Products/Release/aerospace "$ROOT/bin/aerospace"

echo "== signing"
codesign --force --options runtime --sign "$IDENTITY" "$ROOT/AeroSpace.app"
codesign --force --options runtime --sign "$IDENTITY" "$ROOT/bin/aerospace"

ZIP="$PWD/AeroSpace-$PW_TAG.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT" "$ZIP"

if xcrun notarytool history --keychain-profile panewright-notary >/dev/null 2>&1; then
    echo "== notarizing"
    xcrun notarytool submit "$ZIP" --keychain-profile panewright-notary --wait
    xcrun stapler staple "$ROOT/AeroSpace.app"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$ROOT" "$ZIP"
else
    echo "note: no panewright-notary profile — shipping un-notarized"
fi

echo "== releasing $PW_TAG"
git tag -f "$PW_TAG"
git push -f fork "$PW_TAG"
gh release create "$PW_TAG" "$ZIP" --repo nitschw/AeroSpace \
    --title "AeroSpace $PW_TAG (Panewright patches)" \
    --notes "Upstream $BASE_TAG plus Panewright's patches: dock-aware hide corner, hideable menu bar icon. Universal binaries, signed and notarized. See the panewright branch for the diffs."
shasum -a 256 "$ZIP"
