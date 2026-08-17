#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-away-source-install.XXXXXX")

cleanup() {
  rm -rf "$build_dir"
}
trap cleanup EXIT

swift build \
  --package-path "$project_dir" \
  --scratch-path "$build_dir/build" \
  --configuration release \
  --product codex-away

mkdir -p "$build_dir/release"
install -m 700 "$build_dir/build/release/codex-away" "$build_dir/release/codex-away"
install -m 700 "$project_dir/scripts/install-release.sh" "$build_dir/release/install-release.sh"
install -m 600 "$project_dir/com.akibrhast.codex-away.plist.template" "$build_dir/release/com.akibrhast.codex-away.plist.template"
print "source" > "$build_dir/release/VERSION"

codesign --force --sign - "$build_dir/release/codex-away"
CODEX_AWAY_ALLOW_ADHOC=1 /bin/zsh "$build_dir/release/install-release.sh"
