#!/bin/bash
# Assemble Reclip.app from the SwiftPM build output and code-sign it.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Reclip.app"
BIN_NAME="Reclip"

echo "==> swift build ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
[ -f "$BIN" ] || { echo "binary not found at $BIN"; exit 1; }

echo "==> assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
  cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign: use Developer ID if requested via IDENTITY env, else ad-hoc for local testing.
IDENTITY="${IDENTITY:--}"
KEYCHAIN_ARGS=""
[ -n "${SIGN_KEYCHAIN:-}" ] && KEYCHAIN_ARGS="--keychain $SIGN_KEYCHAIN"

echo "==> codesign (identity: $IDENTITY)"
codesign --force --deep --options runtime \
  --entitlements "$ROOT/packaging/Reclip.entitlements" \
  --sign "$IDENTITY" $KEYCHAIN_ARGS "$APP"

echo "==> done: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|flags" || true
