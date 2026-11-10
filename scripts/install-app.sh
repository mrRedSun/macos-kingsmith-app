#!/bin/bash
# Builds the app, replaces /Applications/WalkingPad.app, and relaunches it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/WalkingPad.app"

bash "$ROOT/scripts/build-app.sh"

# Quit the running copy so the new binary takes over.
if pgrep -x WalkingPad >/dev/null; then
    osascript -e 'tell application id "app.walkingpad.native" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do pgrep -x WalkingPad >/dev/null || break; sleep 0.1; done
    pkill -x WalkingPad 2>/dev/null || true
fi

rm -rf "$DEST"
ditto "$ROOT/build/WalkingPad.app" "$DEST"
/usr/bin/codesign --verify --strict "$DEST"
open "$DEST"
printf 'Installed and launched %s\n' "$DEST"
