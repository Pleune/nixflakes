#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/eko24ive/pi-ask.git
archive_base_url=https://github.com/eko24ive/pi-ask/archive/refs/tags
package_file=default.nix

die() { echo "$*" >&2; exit 1; }

latest_tag() {
  git ls-remote --tags --refs "$repo_url" 'v*' \
    | awk -F/ '{print $3}' \
    | grep -E '^v[0-9]+(\.[0-9]+)*$' \
    | sort -V \
    | tail -n1
}

current_rev() {
  sed -n 's/^  version = "\(.*\)";$/v\1/p' "$package_file"
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
  rm -rf "${tmpdir:-}" "${backup_dir:-}"
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

old_hash=$(current_hash)
current_rev=$(current_rev)
[[ -n "$current_rev" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_hash" ]] || die "Failed to determine current hash from $package_file"

latest_rev=$(latest_tag)
[[ -n "$latest_rev" ]] || die "Failed to determine latest upstream tag"

target_rev=$current_rev
version_changed=false
if [[ "$latest_rev" != "$current_rev" ]]; then
  target_rev=$latest_rev
  version_changed=true
fi

tmpdir=$(mktemp -d)
backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$target_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
src_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$src_hash" && "$src_hash" != null ]] || die "Failed to determine source hash"

if [[ "$version_changed" == "true" || "$src_hash" != "$old_hash" ]]; then
  write_package_nix "${target_rev#v}" "$src_hash"
fi

if [[ "$version_changed" == "true" ]]; then
  echo "Updated $package_file to $target_rev"
elif [[ "$src_hash" != "$old_hash" ]]; then
  echo "Updated source hash for $target_rev"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
