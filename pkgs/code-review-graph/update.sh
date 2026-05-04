#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

package_file=default.nix


die() { echo "$*" >&2; exit 1; }

latest_version() {
  git ls-remote --tags --refs https://github.com/tirth8205/code-review-graph 'v*' \
    | awk -F/ '$3 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ { print substr($3, 2) }' \
    | sort -V \
    | tail -n1
}

current_version() {
  sed -n 's/^  version = "\(.*\)";$/\1/p' "$package_file"
}

current_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$package_file"
}

write_package_nix() {
  local version=$1 hash=$2 tmp
  tmp=$(mktemp)

  jq -n --arg version "$version" --arg hash "$hash" '{ version: $version, hash: $hash }' > "$tmp.json"
  jq -r '.version, .hash' < "$tmp.json" >/dev/null

  sed \
    -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
    -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
    "$package_file" > "$tmp"

  mv "$tmp" "$package_file"
  rm -f "$tmp.json"
}

cleanup() {
  rm -rf "${backup_dir:-}"
}

restore_and_cleanup() {
  local status=$?
  if (( status != 0 )); then
    cp "$backup_dir/$package_file" "$package_file" 2>/dev/null || true
  fi
  cleanup
  exit "$status"
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

old_version=$(current_version)
old_hash=$(current_hash)
[[ -n "$old_version" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_hash" ]] || die "Failed to determine current hash from $package_file"

new_version=$(latest_version)
[[ -n "$new_version" ]] || die "Failed to determine latest version"

backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

prefetch_json=$(nix store prefetch-file --json --unpack "https://github.com/tirth8205/code-review-graph/archive/refs/tags/v${new_version}.tar.gz")
new_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$new_hash" && "$new_hash" != null ]] || die "Failed to determine source hash"

if [[ "$new_version" != "$old_version" || "$new_hash" != "$old_hash" ]]; then
  write_package_nix "$new_version" "$new_hash"
fi

if [[ "$new_version" != "$old_version" ]]; then
  echo "Updated $package_file to $new_version"
elif [[ "$new_hash" != "$old_hash" ]]; then
  echo "Updated source hash for $new_version"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
