#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/build/WalkingPad.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WalkingPad" "$APP/Contents/MacOS/WalkingPad"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
# A stable identity keeps macOS's Bluetooth permission across rebuilds; an ad hoc
# signature changes with every build, so macOS treats each one as a new app.
# Override with WALKINGPAD_SIGN_IDENTITY, or set it to "-" for ad hoc.
IDENTITY="${WALKINGPAD_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/ { print $2; exit }')}"
/usr/bin/codesign --force --sign "${IDENTITY:--}" --identifier app.walkingpad.native "$APP"
printf '\nBuilt %s\nOpen with: open "%s"\n' "$APP" "$APP"
