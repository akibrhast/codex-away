#!/bin/sh

set -eu

repository="akibrhast/codex-away"
asset="codex-away-macos-universal.tar.gz"
checksum_asset="$asset.sha256"
version=${CODEX_AWAY_VERSION:-latest}

fail() {
  printf 'Codex Away installation failed: %s\n' "$1" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "macOS is required."

for command_name in curl shasum tar; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

install_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-away-install.XXXXXX")
cleanup() {
  rm -rf "$install_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$version" = "latest" ]; then
  release_url="https://github.com/$repository/releases/latest/download"
else
  case "$version" in
    v[0-9]*) ;;
    *) fail "CODEX_AWAY_VERSION must look like v1.2.3" ;;
  esac
  release_url="https://github.com/$repository/releases/download/$version"
fi

printf 'Downloading Codex Away %s...\n' "$version"
curl --proto '=https' --tlsv1.2 -fsSL "$release_url/$asset" -o "$install_dir/$asset"
curl --proto '=https' --tlsv1.2 -fsSL "$release_url/$checksum_asset" -o "$install_dir/$checksum_asset"

(
  cd "$install_dir"
  shasum -a 256 -c "$checksum_asset"
)

tar -xzf "$install_dir/$asset" -C "$install_dir"
[ -x "$install_dir/install-release.sh" ] || fail "release bundle is missing install-release.sh"

/bin/zsh "$install_dir/install-release.sh"
