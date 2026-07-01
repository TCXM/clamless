#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
DIST="$ROOT/dist"
APP="$BUILD/Clamless.app"
STAGE="$BUILD/dmg-stage"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/app/Info.plist")"
DMG="$DIST/Clamless-$VERSION.dmg"

"$ROOT/scripts/build.sh" >/dev/null

rm -rf "$STAGE"
rm -f "$DMG" "$DMG.sha256"
mkdir -p "$STAGE" "$DIST"

ditto "$APP" "$STAGE/Clamless.app"
ln -s /Applications "$STAGE/Applications"

xattr -cr "$STAGE/Clamless.app" 2>/dev/null || true
codesign --force --deep --sign - "$STAGE/Clamless.app" >/dev/null
codesign --verify --deep --strict "$STAGE/Clamless.app"

hdiutil create \
  -volname "Clamless $VERSION" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

shasum -a 256 "$DMG" > "$DMG.sha256"
echo "$DMG"
