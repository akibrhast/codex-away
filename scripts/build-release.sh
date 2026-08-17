#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
version=${1:-}
output_dir=${2:-"$project_dir/dist"}
asset_name="codex-away-macos-universal"

if [[ ! "$version" =~ '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 "Usage: $0 vMAJOR.MINOR.PATCH [output-directory]"
  exit 1
fi

signing_identity=${CODEX_AWAY_SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" && "${CODEX_AWAY_ALLOW_UNSIGNED:-0}" != 1 ]]; then
  print -u2 "CODEX_AWAY_SIGNING_IDENTITY is required for release builds."
  exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-away-release.XXXXXX")
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

for architecture in arm64 x86_64; do
  CLANG_MODULE_CACHE_PATH="$work_dir/clang-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$work_dir/swiftpm-cache" \
  swift build \
    --package-path "$project_dir" \
    --scratch-path "$work_dir/build-$architecture" \
    --configuration release \
    --product codex-away \
    --triple "$architecture-apple-macosx13.0"
done

bundle_dir="$work_dir/$asset_name"
mkdir -p "$bundle_dir" "$output_dir"
lipo -create \
  "$work_dir/build-arm64/arm64-apple-macosx/release/codex-away" \
  "$work_dir/build-x86_64/x86_64-apple-macosx/release/codex-away" \
  -output "$bundle_dir/codex-away"

if [[ -n "$signing_identity" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$bundle_dir/codex-away"
else
  codesign --force --sign - "$bundle_dir/codex-away"
fi

codesign --verify --strict --verbose=2 "$bundle_dir/codex-away"
[[ "$(lipo -archs "$bundle_dir/codex-away")" == *arm64* ]]
[[ "$(lipo -archs "$bundle_dir/codex-away")" == *x86_64* ]]

install -m 700 "$project_dir/scripts/install-release.sh" "$bundle_dir/install-release.sh"
install -m 600 "$project_dir/com.akibrhast.codex-away.plist.template" "$bundle_dir/com.akibrhast.codex-away.plist.template"
install -m 700 "$project_dir/uninstall.sh" "$bundle_dir/uninstall.sh"
print -r -- "$version" > "$bundle_dir/VERSION"

rm -f "$output_dir/$asset_name.tar.gz" "$output_dir/$asset_name.tar.gz.sha256" "$output_dir/$asset_name-notarization.zip"
COPYFILE_DISABLE=1 tar -czf "$output_dir/$asset_name.tar.gz" -C "$bundle_dir" .
ditto -c -k --keepParent "$bundle_dir" "$output_dir/$asset_name-notarization.zip"

(
  cd "$output_dir"
  shasum -a 256 "$asset_name.tar.gz" > "$asset_name.tar.gz.sha256"
)

print "Built $output_dir/$asset_name.tar.gz"
print "Notarization input: $output_dir/$asset_name-notarization.zip"
