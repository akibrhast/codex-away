#!/bin/zsh

set -euo pipefail

support_dir="$HOME/Library/Application Support/CodexRemoteOnLock"
plist="$HOME/Library/LaunchAgents/com.openai.codex.remote-on-lock.plist"
label="com.openai.codex.remote-on-lock"
codex_bin="$HOME/.codex/packages/standalone/current/codex"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true

if [[ -x "$codex_bin" ]]; then
  "$codex_bin" remote-control stop || true
fi

rm -f "$plist"
rm -f "$support_dir/codex-remote-on-lock"

print "Uninstalled $label"
print "Logs and state remain in: $support_dir"
