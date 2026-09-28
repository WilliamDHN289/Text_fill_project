#!/bin/bash
set -euo pipefail

VERSION="${1:?usage: verify-release.sh <version>   e.g. 1.0.2}"
APPCAST_URL="https://raw.githubusercontent.com/Xin-Jing/flowin-releases/main/appcast.xml"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SIGN_TOOL="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [ ! -x "$SIGN_TOOL" ]; then
    echo "ERROR: sign_update not found at $SIGN_TOOL"
    echo "Run 'swift build' once to fetch Sparkle artifacts."
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Fetching live appcast..."
curl -fsSL -o "$TMP/appcast.xml" "$APPCAST_URL"

# Extract the enclosure for the requested version.
ENTRY=$(awk -v ver="$VERSION" '
  /<title>Version / { inItem = ($0 ~ "Version " ver "<") }
  inItem && /<enclosure/      { capture = 1 }
  capture                     { print }
  inItem && capture && /\/>/  { capture = 0; inItem = 0 }
' "$TMP/appcast.xml")

if [ -z "$ENTRY" ]; then
    echo "ERROR: no entry for version $VERSION in appcast"
    exit 1
fi

URL=$(echo "$ENTRY"          | sed -n 's/.*url="\([^"]*\)".*/\1/p' | head -1)
EXPECTED_SIG=$(echo "$ENTRY" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -1)
EXPECTED_LEN=$(echo "$ENTRY" | sed -n 's/.*length="\([0-9]*\)".*/\1/p' | head -1)

echo "Expected from appcast:"
echo "  url:    $URL"
echo "  length: $EXPECTED_LEN"
echo "  sig:    $EXPECTED_SIG"
echo ""
echo "Downloading published DMG..."
curl -fsSL -o "$TMP/release.dmg" "$URL"

ACTUAL_LEN=$(stat -f %z "$TMP/release.dmg")
ACTUAL_SIG=$("$SIGN_TOOL" "$TMP/release.dmg" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')

echo ""
echo "Actual from DMG:"
echo "  length: $ACTUAL_LEN"
echo "  sig:    $ACTUAL_SIG"
echo ""

MISMATCH=0
if [ "$EXPECTED_LEN" != "$ACTUAL_LEN" ]; then
    echo "MISMATCH: length (appcast=$EXPECTED_LEN, DMG=$ACTUAL_LEN)"
    MISMATCH=1
fi
if [ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]; then
    echo "MISMATCH: edSignature"
    MISMATCH=1
fi

if [ $MISMATCH -ne 0 ]; then
    echo ""
    echo "Users on older versions will see 'update is improperly signed' when Sparkle tries v$VERSION."
    exit 1
fi

echo "OK: appcast matches published DMG for v$VERSION"
