#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Clamless.app"
PLIST="$HOME/Library/LaunchAgents/local.clamless.menu.plist"
OLD_PLIST_2="$HOME/Library/LaunchAgents/local.openlid.menu.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/local.openlid-display.menu.plist"

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/install-app.sh" >/dev/null
fi

mkdir -p "$HOME/Library/LaunchAgents"
launchctl unload "$OLD_PLIST_2" >/dev/null 2>&1 || true
launchctl unload "$OLD_PLIST" >/dev/null 2>&1 || true
rm -f "$OLD_PLIST_2"
rm -f "$OLD_PLIST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.clamless.menu</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-g</string>
    <string>${APP}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"
echo "$PLIST"
