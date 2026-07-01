#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

legacy_plists=(
  "$HOME/Library/LaunchAgents/local.clamless.menu.plist"
  "$HOME/Library/LaunchAgents/local.openlid.menu.plist"
  "$HOME/Library/LaunchAgents/local.openlid-display.menu.plist"
)

cleanup_legacy_launch_agents() {
  for plist in "${legacy_plists[@]}"; do
    launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
    launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
  done
}

find_clamless_app() {
  local candidate

  if [[ -n "${CLAMLESS_APP:-}" && -d "$CLAMLESS_APP" ]]; then
    printf '%s\n' "$CLAMLESS_APP"
    return 0
  fi

  for candidate in \
    "/Applications/Clamless.app" \
    "$HOME/Applications/Clamless.app" \
    "$ROOT/.build/Clamless.app"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

app_supports_login_item_command() {
  local app="$1"
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
  awk -F. -v version="$version" 'BEGIN {
    split(version, current, ".")
    split("0.1.2", minimum, ".")
    for (i = 1; i <= 3; i++) {
      c = current[i] + 0
      m = minimum[i] + 0
      if (c > m) exit 0
      if (c < m) exit 1
    }
    exit 0
  }'
}

cleanup_legacy_launch_agents

app="$(find_clamless_app || true)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "Removed legacy Clamless LaunchAgents. No installed Clamless.app was found."
  exit 0
fi

if ! app_supports_login_item_command "$app"; then
  echo "Removed legacy Clamless LaunchAgents."
  echo "Installed Clamless.app is older than the Open at Login command bridge."
  echo "Open the current Clamless Settings to manage Open at Login."
  exit 0
fi

executable="$app/Contents/MacOS/ClamlessMenu"
if [[ ! -x "$executable" ]]; then
  echo "Removed legacy Clamless LaunchAgents. Clamless.app executable was not found."
  exit 0
fi

if output="$("$executable" --unregister-login-item 2>&1)"; then
  echo "$output"
else
  echo "$output"
  echo "Removed legacy Clamless LaunchAgents. Open at Login may already be disabled."
fi
