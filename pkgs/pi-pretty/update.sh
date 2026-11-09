#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/heyhuynhgiabuu/pi-pretty.git
archive_base_url=https://github.com/heyhuynhgiabuu/pi-pretty/archive
package_file=default.nix
flake_attr=.#legacyPackages.x86_64-linux.pi-pretty

die() { echo "$*" >&2; exit 1; }

current_version() {
  sed -n 's/^  version = "\(.*\)";$/\1/p' "$package_file"
}

current_src_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$package_file"
}

current_npm_hash() {
  sed -n 's/^  npmDepsHash = "\(.*\)";$/\1/p' "$package_file"
}

write_package_nix() {
  local version=$1 src_hash=$2 npm_hash=$3 tmp
  tmp=$(mktemp)

  awk \
    -v version="$version" \
    -v src_hash="$src_hash" \
    -v npm_hash="$npm_hash" '
      /^  version = "/ { print "  version = \"" version "\";"; next }
      /^    hash = "/ { print "    hash = \"" src_hash "\";"; next }
      /^  npmDepsHash = "/ { print "  npmDepsHash = \"" npm_hash "\";"; next }
      { print }
    ' "$package_file" > "$tmp"

  mv "$tmp" "$package_file"
}

# Probe the npm dependency hash by building with a throwaway hash and reading
# the `got:` value from the fixed-output mismatch.
probe_npm_hash() {
  local repo_root=$1 got
  got=$(cd "$repo_root" && nix build --no-link --option eval-cache false "$flake_attr" 2>&1 |
    sed -n 's/.*got:[[:space:]]*\(sha256-[^ ]*\).*/\1/p' | head -1)
  [[ -n "$got" ]] || die "Failed to determine npmDepsHash from the build output"
  printf '%s' "$got"
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

old_version=$(current_version)
old_src_hash=$(current_src_hash)
old_npm_hash=$(current_npm_hash)
[[ -n "$old_version" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_src_hash" ]] || die "Failed to determine current source hash from $package_file"
[[ -n "$old_npm_hash" ]] || die "Failed to determine current npmDepsHash from $package_file"

tag=$(git ls-remote --tags --refs "$repo_url" |
  awk '{print $2}' | sed 's|^refs/tags/||' | grep -E '^v[0-9]' | sort -V | tail -1 || true)
[[ -n "$tag" ]] || die "Failed to determine latest upstream tag"
version=${tag#v}

prefetch_json=$(nix store prefetch-file --json --unpack "$archive_base_url/$tag.tar.gz")
src_hash=$(jq -er .hash <<< "$prefetch_json")
[[ -n "$version" && -n "$src_hash" ]] || die "Failed to determine upstream tag or source hash"

backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap 'cp "$backup_dir/$package_file" "$package_file" 2>/dev/null || true; rm -rf "$backup_dir"' EXIT

if [[ "$version" == "$old_version" && "$src_hash" == "$old_src_hash" ]]; then
  echo "No upstream changes (still $version)"
  trap - EXIT
  exit 0
fi

# Dependencies are version-specific, so probe them with a fresh source.
write_package_nix "$version" "$src_hash" "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
repo_root=$(cd -- "$script_dir/../.." && pwd)
npm_hash=$(probe_npm_hash "$repo_root")

write_package_nix "$version" "$src_hash" "$npm_hash"
echo "Updated package to $version ($tag)"

trap - EXIT
