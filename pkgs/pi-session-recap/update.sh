#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

# Upstream is a monorepo (tmustier/pi-extensions) with per-package tags, so the
# tag prefix here is what identifies this package's releases.
repo_url=https://github.com/tmustier/pi-extensions.git
archive_base_url=https://github.com/tmustier/pi-extensions/archive/refs/tags
tag_prefix=session-recap/v
package_file=default.nix

die() { echo "$*" >&2; exit 1; }

latest_tag() {
  git ls-remote --tags --refs "$repo_url" "${tag_prefix}*" \
    | awk '{print $2}' \
    | sed 's|^refs/tags/||' \
    | grep -E "^${tag_prefix}[0-9]+(\.[0-9]+)*$" \
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
  local ver=$1 hash=$2 tmp
  tmp=$(mktemp)
  sed \
    -e "s|^  version = \".*\";$|  version = \"${ver}\";|" \
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

old_version=$(current_version)
old_hash=$(current_hash)
[[ -n "$old_version" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_hash" ]] || die "Failed to determine current hash from $package_file"

latest_rev=$(latest_tag)
[[ -n "$latest_rev" ]] || die "Failed to determine latest upstream tag for ${tag_prefix}"
latest_version=${latest_rev#"$tag_prefix"}

tmpdir=$(mktemp -d)
backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$latest_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
src_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$src_hash" && "$src_hash" != null ]] || die "Failed to determine source hash"

if [[ "$latest_version" != "$old_version" || "$src_hash" != "$old_hash" ]]; then
  write_package_nix "$latest_version" "$src_hash"
fi

if [[ "$latest_version" != "$old_version" ]]; then
  echo "Updated $package_file to $latest_rev"
elif [[ "$src_hash" != "$old_hash" ]]; then
  echo "Updated source hash for $latest_rev"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
