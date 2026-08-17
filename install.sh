#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h}
support_dir="$HOME/Library/Application Support/CodexRemoteOnLock"
launch_agents_dir="$HOME/Library/LaunchAgents"
plist="$launch_agents_dir/com.openai.codex.remote-on-lock.plist"
label="com.openai.codex.remote-on-lock"
codex_bin="$HOME/.codex/packages/standalone/current/codex"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-remote-on-lock.XXXXXX")

cleanup() {
  rm -rf "$build_dir"
}
trap cleanup EXIT

if [[ ! -x "$codex_bin" ]]; then
  print -u2 "Standalone Codex was not found at: $codex_bin"
  print -u2 "Install it using: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
  exit 1
fi

mkdir -p "$support_dir" "$launch_agents_dir"

swift build \
  --package-path "$project_dir" \
  --scratch-path "$build_dir/build" \
  --configuration release \
  --product codex-remote-on-lock

sed "s|__HOME__|$HOME|g" \
  "$project_dir/com.openai.codex.remote-on-lock.plist.template" \
  > "$build_dir/$label.plist"

plutil -lint "$build_dir/$label.plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true

install -m 700 "$build_dir/build/release/codex-remote-on-lock" "$support_dir/codex-remote-on-lock"
install -m 600 "$build_dir/$label.plist" "$plist"
launchctl bootstrap "gui/$(id -u)" "$plist"

print "Installed and started $label"
print "Logs: $support_dir/controller.log"
