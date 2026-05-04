#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

repo_owner=chandra447
repo_name=pi-hermes-memory
archive_base_url=https://github.com/$repo_owner/$repo_name/archive/refs/tags
package_file=default.nix

die() { echo "$*" >&2; exit 1; }

latest_release_info() {
  local tag version rev

  tag=$(
    git ls-remote --tags --sort=-version:refname "https://github.com/$repo_owner/$repo_name" 'v*' \
      | awk '!/\^\{\}$/ { sub("refs/tags/", "", $2); print $2; exit }'
  )
  [[ -n "$tag" ]] || die "Failed to determine latest tag"

  version=${tag#v}
  rev=$tag

  jq -n --arg version "$version" --arg rev "$rev" '{ version: $version, rev: $rev }'
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

  sed \
    -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
    -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
    "$package_file" > "$tmp"

  mv "$tmp" "$package_file"
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

release_json=$(latest_release_info)
new_version=$(jq -r '.version' <<< "$release_json")
new_rev=$(jq -r '.rev' <<< "$release_json")
[[ -n "$new_version" && "$new_version" != null ]] || die "Failed to determine latest version"
[[ -n "$new_rev" && "$new_rev" != null ]] || die "Failed to determine latest revision"

backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$new_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
new_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$new_hash" && "$new_hash" != null ]] || die "Failed to determine source hash"

if [[ "$new_version" != "$old_version" || "$new_hash" != "$old_hash" ]]; then
  write_package_nix "$new_version" "$new_hash"
fi

if [[ "$new_version" != "$old_version" ]]; then
  echo "Updated $package_file to $new_version ($new_rev)"
elif [[ "$new_hash" != "$old_hash" ]]; then
  echo "Updated source hash for $new_version"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
