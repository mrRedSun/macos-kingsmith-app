#!/bin/bash
# Regenerates the compiled app icon in Resources/Icon from Resources/AppIcon.icon.
# Needs full Xcode (actool). The output is committed, so building the app doesn't.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift scripts/draw-icon.swift Resources/AppIcon.icon/Assets
mkdir -p Resources/Icon
PARTIAL="$(mktemp)"
xcrun actool Resources/AppIcon.icon --compile Resources/Icon --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$PARTIAL" >/dev/null
rm -f "$PARTIAL"
ls -l Resources/Icon
