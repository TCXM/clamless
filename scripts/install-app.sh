#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.build/Clamless.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Clamless.app"
OLD_DEST="$DEST_DIR/OpenLid Display.app"
OLD_DEST_2="$DEST_DIR/OpenLid.app"

"$ROOT/scripts/build.sh" >/dev/null

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
rm -rf "$OLD_DEST"
rm -rf "$OLD_DEST_2"
ditto "$SRC" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
codesign --force --deep --sign - "$DEST" >/dev/null
codesign --verify --deep --strict "$DEST"

echo "$DEST"
