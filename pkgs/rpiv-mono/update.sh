#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

repo_owner=juicesharp
repo_name=rpiv-mono
archive_base_url=https://github.com/$repo_owner/$repo_name/archive/refs/tags
source_file=src.nix
voice_package_attr=rpiv-voice
fake_npm_deps_hash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

die() { echo "$*" >&2; exit 1; }

latest_release_info() {
  local tag version

  tag=$(
    git ls-remote --tags --sort=-version:refname "https://github.com/$repo_owner/$repo_name" 'v*' \
      | awk '!/\^\{\}$/ { sub("refs/tags/", "", $2); print $2; exit }'
  )
  [[ -n "$tag" ]] || die "Failed to determine latest tag"

  version=${tag#v}
  jq -n --arg version "$version" '{ version: $version }'
}

current_version() {
  sed -n 's/^  version = "\(.*\)";$/\1/p' "$source_file"
}

current_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$source_file"
}

current_npm_deps_hash() {
  sed -n 's/^  npmDepsHash = "\(.*\)";$/\1/p' "$source_file"
}

write_source_nix() {
  local version=$1 hash=$2 npm_deps_hash=$3 tmp
  tmp=$(mktemp)

  sed \
    -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
    -e "s|^  npmDepsHash = \".*\";$|  npmDepsHash = \"${npm_deps_hash}\";|" \
    -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
    "$source_file" > "$tmp"

  mv "$tmp" "$source_file"
}

prefetch_npm_deps_hash() {
  local repo_root build_log status

  repo_root=$(git rev-parse --show-toplevel)
  build_log=$(mktemp)

  write_source_nix "$new_version" "$new_hash" "$fake_npm_deps_hash"

  set +e
  (cd "$repo_root" && nix build --no-link ".#legacyPackages.x86_64-linux.$voice_package_attr") >"$build_log" 2>&1
  status=$?
  set -e

  if (( status == 0 )); then
    rm -f "$build_log"
    die "Unexpectedly resolved npmDepsHash without a mismatch while probing $voice_package_attr"
  fi

  sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\)$/\1/p' "$build_log" | tail -n 1
  rm -f "$build_log"
}

cleanup() {
  rm -rf "${backup_dir:-}"
}

restore_and_cleanup() {
  local status=$?
  if (( status != 0 )); then
    cp "$backup_dir/$source_file" "$source_file" 2>/dev/null || true
  fi
  cleanup
  exit "$status"
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

old_version=$(current_version)
old_hash=$(current_hash)
old_npm_deps_hash=$(current_npm_deps_hash)
[[ -n "$old_version" ]] || die "Failed to determine current version from $source_file"
[[ -n "$old_hash" ]] || die "Failed to determine current hash from $source_file"
[[ -n "$old_npm_deps_hash" ]] || die "Failed to determine current npmDepsHash from $source_file"

release_json=$(latest_release_info)
new_version=$(jq -r '.version' <<< "$release_json")
[[ -n "$new_version" && "$new_version" != null ]] || die "Failed to determine latest version"

backup_dir=$(mktemp -d)
cp "$source_file" "$backup_dir/$source_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/v$new_version.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
new_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$new_hash" && "$new_hash" != null ]] || die "Failed to determine source hash"

new_npm_deps_hash="$old_npm_deps_hash"
if [[ "$new_version" != "$old_version" || "$new_hash" != "$old_hash" ]]; then
  new_npm_deps_hash=$(prefetch_npm_deps_hash)
  [[ -n "$new_npm_deps_hash" ]] || die "Failed to determine npmDepsHash"
  write_source_nix "$new_version" "$new_hash" "$new_npm_deps_hash"
fi

if [[ "$new_version" != "$old_version" ]]; then
  echo "Updated $source_file to $new_version"
elif [[ "$new_hash" != "$old_hash" || "$new_npm_deps_hash" != "$old_npm_deps_hash" ]]; then
  echo "Updated shared source metadata for $new_version"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
