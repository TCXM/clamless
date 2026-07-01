#!/bin/zsh
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/local.clamless.menu.plist"
OLD_PLIST_2="$HOME/Library/LaunchAgents/local.openlid.menu.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/local.openlid-display.menu.plist"

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl unload "$OLD_PLIST_2" >/dev/null 2>&1 || true
launchctl unload "$OLD_PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -f "$OLD_PLIST_2"
rm -f "$OLD_PLIST"
echo "$PLIST"
