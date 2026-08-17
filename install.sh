#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h}
user_domain="gui/$(id -u)"
launch_agents_dir="$HOME/Library/LaunchAgents"

label="com.akibrhast.codex-away"
support_dir="$HOME/Library/Application Support/CodexAway"
plist="$launch_agents_dir/$label.plist"
executable="$support_dir/codex-away"

legacy_label="com.openai.codex.remote-on-lock"
legacy_support_dir="$HOME/Library/Application Support/CodexRemoteOnLock"
legacy_plist="$launch_agents_dir/$legacy_label.plist"
legacy_executable="$legacy_support_dir/codex-remote-on-lock"

codex_bin="$HOME/.codex/packages/standalone/current/codex"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-away.XXXXXX")
legacy_was_loaded=false
new_was_loaded=false
install_succeeded=false

cleanup() {
  local exit_status=$?
  rm -rf "$build_dir"

  if [[ $exit_status -ne 0 && "$install_succeeded" == false ]]; then
    if [[ "$legacy_was_loaded" == true && -f "$legacy_plist" ]]; then
      print -u2 "Codex Away installation failed; attempting to restore the legacy LaunchAgent."
      launchctl bootstrap "$user_domain" "$legacy_plist" 2>/dev/null || true
    elif [[ "$new_was_loaded" == true && -f "$plist" ]]; then
      print -u2 "Codex Away reinstallation failed; attempting to restore its LaunchAgent."
      launchctl bootstrap "$user_domain" "$plist" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

if [[ ! -x "$codex_bin" ]]; then
  print -u2 "Standalone Codex was not found at: $codex_bin"
  print -u2 "Install it using: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
  exit 1
fi

swift build \
  --package-path "$project_dir" \
  --scratch-path "$build_dir/build" \
  --configuration release \
  --product codex-away

sed "s|__HOME__|$HOME|g" \
  "$project_dir/com.akibrhast.codex-away.plist.template" \
  > "$build_dir/$label.plist"

plutil -lint "$build_dir/$label.plist"

if launchctl print "$user_domain/$legacy_label" >/dev/null 2>&1; then
  legacy_was_loaded=true
fi
if launchctl print "$user_domain/$label" >/dev/null 2>&1; then
  new_was_loaded=true
fi

if [[ "$legacy_was_loaded" == true && "$new_was_loaded" == true ]]; then
  print -u2 "Both legacy and Codex Away LaunchAgents are loaded; refusing an ambiguous migration."
  exit 1
fi

legacy_ownership="$legacy_support_dir/service-ownership.json"
new_ownership="$support_dir/service-ownership.json"
if [[ "$legacy_was_loaded" == true && -f "$legacy_ownership" && -f "$new_ownership" ]] && ! cmp -s "$legacy_ownership" "$new_ownership"; then
  print -u2 "Legacy and Codex Away ownership records conflict; refusing to choose one automatically."
  exit 1
fi

launchctl bootout "$user_domain/$label" 2>/dev/null || true
launchctl bootout "$user_domain/$legacy_label" 2>/dev/null || true

mkdir -p "$support_dir" "$launch_agents_dir"

# Copy legacy runtime evidence before starting the new controller. The legacy
# files remain intact until the new LaunchAgent is verified, allowing rollback.
for state_file in service-ownership.json state controller.log launchd.log launchd-error.log; do
  if [[ -f "$legacy_support_dir/$state_file" && ! -e "$support_dir/$state_file" ]]; then
    cp -p "$legacy_support_dir/$state_file" "$support_dir/$state_file"
  fi
done

install -m 700 "$build_dir/build/release/codex-away" "$executable"
install -m 600 "$build_dir/$label.plist" "$plist"
launchctl bootstrap "$user_domain" "$plist"
launchctl print "$user_domain/$label" >/dev/null
install_succeeded=true

# Retire only known legacy artifacts after the new controller is running.
rm -f "$legacy_plist" "$legacy_executable"
for state_file in service-ownership.json state controller.log launchd.log launchd-error.log; do
  rm -f "$legacy_support_dir/$state_file"
done
rmdir "$legacy_support_dir" 2>/dev/null || true

print "Installed and started $label"
print "Logs: $support_dir/controller.log"
