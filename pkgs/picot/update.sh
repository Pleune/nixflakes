#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/shixin-guo/picot.git
archive_base_url=https://github.com/shixin-guo/picot/archive/refs/tags
package_file=default.nix
fake_hash='sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='

die() { echo "$*" >&2; exit 1; }

latest_tag() {
  git ls-remote --tags --refs "$repo_url" 'v*' \
    | awk -F/ '{print $3}' \
    | grep -E '^v[0-9]+(\.[0-9]+)*([-.][0-9A-Za-z.]+)?$' \
    | sort -V \
    | tail -n1
}

current_version() {
  sed -n 's/^[[:space:]]*version = "\(.*\)";$/\1/p' "$package_file"
}

current_src_hash() {
  awk 'BEGIN { count = 0 } /^[[:space:]]*hash = "/ { count++; if (count == 1) { sub(/^[[:space:]]*hash = "/, ""); sub(/";$/, ""); print; exit } }' "$package_file"
}

current_node_modules_hash() {
  sed -n 's/^[[:space:]]*outputHash = "\(.*\)";$/\1/p' "$package_file"
}

current_cargo_hash() {
  sed -n 's/^[[:space:]]*cargoHash = "\(.*\)";$/\1/p' "$package_file"
}

write_package_nix() {
  local version=$1 src_hash=$2 node_modules_hash=$3 cargo_hash=$4 tmp
  tmp=$(mktemp)

  awk \
    -v version="$version" \
    -v src_hash="$src_hash" \
    -v node_modules_hash="$node_modules_hash" \
    -v cargo_hash="$cargo_hash" '
      BEGIN { src_hash_done = 0 }
      /^[[:space:]]*version = "/ {
        sub(/version = ".*";/, "version = \"" version "\";")
        print
        next
      }
      /^[[:space:]]*hash = "/ && src_hash_done == 0 {
        sub(/hash = ".*";/, "hash = \"" src_hash "\";")
        print
        src_hash_done = 1
        next
      }
      /^[[:space:]]*outputHash = "/ {
        sub(/outputHash = ".*";/, "outputHash = \"" node_modules_hash "\";")
        print
        next
      }
      /^[[:space:]]*cargoHash = "/ {
        sub(/cargoHash = ".*";/, "cargoHash = \"" cargo_hash "\";")
        print
        next
      }
      { print }
    ' "$package_file" > "$tmp"

  mv "$tmp" "$package_file"
}

capture_hash() {
  local build_attr=$1
  local output

  output=$(
    nix build --option eval-cache false --no-link "$build_attr" 2>&1 >/dev/null || true
  )

  sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' <<< "$output" | tail -n1
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
old_src_hash=$(current_src_hash)
old_node_modules_hash=$(current_node_modules_hash)
old_cargo_hash=$(current_cargo_hash)

[[ -n "$old_version" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_src_hash" ]] || die "Failed to determine current source hash from $package_file"
[[ -n "$old_node_modules_hash" ]] || die "Failed to determine current node_modules hash from $package_file"
[[ -n "$old_cargo_hash" ]] || die "Failed to determine current cargo hash from $package_file"

latest_rev=$(latest_tag)
[[ -n "$latest_rev" ]] || die "Failed to determine latest upstream tag"

new_version=${latest_rev#v}
archive_url="$archive_base_url/$latest_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
new_src_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$new_src_hash" && "$new_src_hash" != null ]] || die "Failed to determine source hash"

backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

write_package_nix "$new_version" "$new_src_hash" "$fake_hash" "$old_cargo_hash"
new_node_modules_hash=$(capture_hash '.#legacyPackages.x86_64-linux.picot.node_modules')
[[ -n "$new_node_modules_hash" ]] || die "Failed to determine node_modules hash"

write_package_nix "$new_version" "$new_src_hash" "$new_node_modules_hash" "$fake_hash"
new_cargo_hash=$(capture_hash '.#legacyPackages.x86_64-linux.picot')
[[ -n "$new_cargo_hash" ]] || die "Failed to determine cargo hash"

write_package_nix "$new_version" "$new_src_hash" "$new_node_modules_hash" "$new_cargo_hash"

if [[ "$new_version" != "$old_version" ]]; then
  echo "Updated $package_file to v$new_version"
elif [[ "$new_src_hash" != "$old_src_hash" || "$new_node_modules_hash" != "$old_node_modules_hash" || "$new_cargo_hash" != "$old_cargo_hash" ]]; then
  echo "Updated package metadata for v$new_version"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
