#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/ttttmr/pi-web-search.git
archive_base_url=https://github.com/ttttmr/pi-web-search/archive
package_file=default.nix

die() { echo "$*" >&2; exit 1; }

current_value() {
  local pattern=$1
  sed -n "s|${pattern}|\\1|p" "$package_file"
}

write_package_nix() {
  local version=$1 rev=$2 hash=$3 tmp
  tmp=$(mktemp)
  sed \
    -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
    -e "s|^  rev = \".*\";$|  rev = \"${rev}\";|" \
    -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
    "$package_file" > "$tmp"
  mv "$tmp" "$package_file"
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

old_version=$(current_value '^  version = "\(.*\)";$')
old_rev=$(current_value '^  rev = "\(.*\)";$')
old_hash=$(current_value '^    hash = "\(.*\)";$')
[[ -n "$old_version" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_rev" ]] || die "Failed to determine current revision from $package_file"
[[ -n "$old_hash" ]] || die "Failed to determine current source hash from $package_file"

latest_rev=$(git ls-remote "$repo_url" refs/heads/main | awk 'NR == 1 { print $1 }')
[[ -n "$latest_rev" ]] || die "Failed to determine latest upstream main revision"

tmpdir=$(mktemp -d)
backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$latest_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
src_hash=$(jq -r .hash <<< "$prefetch_json")
src_path=$(jq -r .storePath <<< "$prefetch_json")
version=$(jq -r .version "$src_path/package.json")
[[ -n "$src_hash" && "$src_hash" != null ]] || die "Failed to determine source hash"
[[ -n "$version" && "$version" != null ]] || die "Failed to determine upstream package version"

if [[ "$version" != "$old_version" || "$latest_rev" != "$old_rev" || "$src_hash" != "$old_hash" ]]; then
  write_package_nix "$version" "$latest_rev" "$src_hash"
fi

if [[ "$latest_rev" != "$old_rev" ]]; then
  echo "Updated $package_file to $version at $latest_rev"
elif [[ "$src_hash" != "$old_hash" ]]; then
  echo "Updated source hash for $latest_rev"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
