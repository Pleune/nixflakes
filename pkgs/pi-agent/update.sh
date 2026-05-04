#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#nodejs -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/earendil-works/pi.git
archive_base_url=https://github.com/earendil-works/pi/archive/refs/tags
package_file=default.nix
models_file=models.generated.ts
package_lock_file=package-lock.json

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

write_package_nix() {
  local version=$1 hash=$2 npm_deps_hash=$3 tmp
  tmp=$(mktemp)

  jq -n \
    --arg version "$version" \
    --arg hash "$hash" \
    --arg npmDepsHash "$npm_deps_hash" \
    '{ version: $version, hash: $hash, npmDepsHash: $npmDepsHash }' > "$tmp.json"

  jq -r '.version' < "$tmp.json" >/dev/null

  sed \
    -e "s|^  version = \".*\";\$|  version = \"${version}\";|" \
    -e "s|^    hash = \".*\";\$|    hash = \"${hash}\";|" \
    -e "s|^  npmDepsHash = \".*\";\$|  npmDepsHash = \"${npm_deps_hash}\";|" \
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
    cp "$backup_dir/$models_file" "$models_file" 2>/dev/null || true
    cp "$backup_dir/$package_lock_file" "$package_lock_file" 2>/dev/null || true
  fi
  cleanup
  exit "$status"
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

current_rev=$(current_rev)
[[ -n "$current_rev" ]] || die "Failed to determine current version from $package_file"

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
if [[ -f "$models_file" ]]; then
  cp "$models_file" "$backup_dir/$models_file"
fi
if [[ -f "$package_lock_file" ]]; then
  cp "$package_lock_file" "$backup_dir/$package_lock_file"
fi
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$target_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
src_hash=$(jq -r .hash <<< "$prefetch_json")
src_path=$(jq -r .storePath <<< "$prefetch_json")

cp -R "$src_path"/. "$tmpdir"/
chmod -R u+w "$tmpdir"
[[ -f "$tmpdir/package-lock.json" ]] || die "Upstream archive does not contain package-lock.json"
cp "$tmpdir/package-lock.json" "$package_lock_file"

echo "Generating model definitions for $target_rev..."
pushd "$tmpdir" >/dev/null
export NPM_CONFIG_YES=true
npm ci --ignore-scripts
npm run generate-models --workspace=packages/ai
popd >/dev/null

generated_models="$tmpdir/packages/ai/src/models.generated.ts"
[[ -f "$generated_models" ]] || die "Model generation did not produce $generated_models"

models_changed=false
if [[ ! -f "$models_file" ]] || ! cmp -s "$generated_models" "$models_file"; then
  cp "$generated_models" "$models_file"
  models_changed=true
  echo "Updated $models_file"
else
  echo "$models_file is already up to date"
fi

npm_deps_hash=$(nix run --inputs-from ../.. nixpkgs#prefetch-npm-deps -- "$package_lock_file" | tail -n1)
[[ -n "$npm_deps_hash" ]] || die "Failed to determine npmDepsHash"

if [[ "$version_changed" == "true" || "$npm_deps_hash" != "$(sed -n 's/^  npmDepsHash = \"\(.*\)\";$/\1/p' "$package_file")" ]]; then
  write_package_nix "${target_rev#v}" "$src_hash" "$npm_deps_hash"
fi

if [[ "$version_changed" == "true" ]]; then
  echo "Updated $package_file to $target_rev"
elif [[ "$models_changed" == "true" ]]; then
  echo "Updated models for $target_rev"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
