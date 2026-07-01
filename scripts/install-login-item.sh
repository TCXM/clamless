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

cleanup_legacy_launch_agents

if [[ -n "${CLAMLESS_APP:-}" && -d "$CLAMLESS_APP" ]]; then
  app="$CLAMLESS_APP"
elif [[ -x "$ROOT/scripts/install-app.sh" ]]; then
  app="$("$ROOT/scripts/install-app.sh" 2>/dev/null || true)"
else
  app="$(find_clamless_app || true)"
fi

if [[ -z "$app" || ! -d "$app" ]]; then
  echo "Clamless.app was not found."
  echo "Install Clamless first, then enable Open at Login from Clamless Settings."
  exit 1
fi

executable="$app/Contents/MacOS/ClamlessMenu"
if [[ ! -x "$executable" ]]; then
  echo "Clamless.app is missing its executable: $executable"
  echo "Reinstall Clamless, then enable Open at Login from Clamless Settings."
  exit 1
fi

if output="$("$executable" --register-login-item 2>&1)"; then
  echo "$output"
  echo "Open at Login is managed by macOS Login Items."
else
  echo "$output"
  echo "Could not enable Open at Login automatically."
  echo "Open Clamless Settings and enable Open at Login manually."
  exit 1
fi
