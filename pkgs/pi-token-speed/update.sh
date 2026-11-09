#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/gsanhueza/pi-token-speed.git
archive_base_url=https://github.com/gsanhueza/pi-token-speed/archive
package_file=default.nix

die() { echo "$*" >&2; exit 1; }

current_rev() {
  sed -n 's/^  rev = "\(.*\)";$/\1/p' "$package_file"
}

current_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$package_file"
}

current_version() {
  sed -n 's/^  version = "\(.*\)";$/\1/p' "$package_file"
}

write_package_nix() {
  local version=$1 rev=$2 hash=$3 tmp
  tmp=$(mktemp)

  awk \
    -v version="$version" \
    -v rev="$rev" \
    -v hash="$hash" '
      /^  version = "/ { print "  version = \"" version "\";"; next }
      /^  rev = "/ { print "  rev = \"" rev "\";"; next }
      /^    hash = "/ { print "    hash = \"" hash "\";"; next }
      { print }
    ' "$package_file" > "$tmp"

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

old_rev=$(current_rev)
old_hash=$(current_hash)
old_version=$(current_version)
[[ -n "$old_rev" ]] || die "Failed to determine current revision from $package_file"
[[ -n "$old_hash" ]] || die "Failed to determine current source hash from $package_file"
[[ -n "$old_version" ]] || die "Failed to determine current version from $package_file"

latest_rev=$(git ls-remote "$repo_url" HEAD | cut -f1)
[[ "$latest_rev" =~ ^[0-9a-f]{40}$ ]] || die "Failed to determine latest upstream main revision"

version=$(curl -fsSL "https://raw.githubusercontent.com/gsanhueza/pi-token-speed/$latest_rev/package.json" | jq -er .version)
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_base_url/$latest_rev.tar.gz")
src_hash=$(jq -er .hash <<< "$prefetch_json")
[[ -n "$version" && -n "$src_hash" ]] || die "Failed to determine upstream package version or source hash"

backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

if [[ "$latest_rev" != "$old_rev" || "$src_hash" != "$old_hash" || "$version" != "$old_version" ]]; then
  write_package_nix "$version" "$latest_rev" "$src_hash"
  echo "Updated package to $version ($latest_rev)"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
