#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
APP="$BUILD/Clamless.app"
HELPER="$BUILD/clamless-display"
OLD_APP="$BUILD/OpenLid Display.app"
OLD_APP_2="$BUILD/OpenLid.app"

rm -rf "$OLD_APP"
rm -rf "$OLD_APP_2"
rm -rf "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang "$ROOT/src/helper/clamless-display.c" \
  -o "$HELPER" \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework IOKit

swiftc "$ROOT/src/menubar/main.swift" \
  -o "$APP/Contents/MacOS/ClamlessMenu" \
  -framework Carbon \
  -framework Cocoa \
  -framework IOKit \
  -framework ServiceManagement

cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
if [[ -d "$ROOT/app/Resources" ]]; then
  ditto "$ROOT/app/Resources" "$APP/Contents/Resources"
fi
swift "$ROOT/scripts/generate-icon.swift" "$APP/Contents/Resources/AppIcon.icns" >/dev/null
cp "$HELPER" "$APP/Contents/Resources/clamless-display"
chmod +x "$HELPER" "$APP/Contents/MacOS/ClamlessMenu" "$APP/Contents/Resources/clamless-display"

xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
