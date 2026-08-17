#!/bin/zsh

set -euo pipefail

user_domain="gui/$(id -u)"
label="com.akibrhast.codex-away"
support_dir="$HOME/Library/Application Support/CodexAway"
plist="$HOME/Library/LaunchAgents/$label.plist"

legacy_label="com.openai.codex.remote-on-lock"
legacy_support_dir="$HOME/Library/Application Support/CodexRemoteOnLock"
legacy_plist="$HOME/Library/LaunchAgents/$legacy_label.plist"

codex_bin="$HOME/.codex/packages/standalone/current/codex"

launchctl bootout "$user_domain/$label" 2>/dev/null || true
launchctl bootout "$user_domain/$legacy_label" 2>/dev/null || true

if [[ -x "$codex_bin" ]]; then
  "$codex_bin" remote-control stop || true
fi

rm -f "$plist" "$legacy_plist"
rm -f "$support_dir/codex-away"
rm -f "$support_dir/VERSION"
rm -f "$legacy_support_dir/codex-remote-on-lock"

print "Uninstalled $label"
print "Logs and state remain in: $support_dir"
