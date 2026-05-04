#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#nodejs -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/nicobailon/pi-subagents.git
archive_base_url=https://github.com/nicobailon/pi-subagents/archive/refs/tags
package_file=default.nix

die() { echo "$*" >&2; exit 1; }

latest_release_info() {
  local line rev tag version

  line=$(git ls-remote --tags --refs "$repo_url" 'v*' \
    | awk '$2 ~ /^refs\/tags\/v[0-9]+(\.[0-9]+)*$/ { print $1 "\t" substr($2, 11) }' \
    | sort -t$'\t' -k2,2V \
    | tail -n1)

  [[ -n "$line" ]] || die "Failed to determine latest upstream tag"

  rev=${line%%$'\t'*}
  tag=${line#*$'\t'}
  version=${tag#v}

  jq -n \
    --arg version "$version" \
    --arg rev "$rev" \
    --arg tag "$tag" \
    '{ version: $version, rev: $rev, tag: $tag }'
}

current_version() {
  sed -n 's/^  version = "\(.*\)";$/\1/p' "$package_file"
}

current_rev() {
  sed -n 's/^    rev = "\(.*\)";$/\1/p' "$package_file"
}

current_hash() {
  awk 'BEGIN { count = 0 } /^    hash = "/ { count++; if (count == 1) { sub(/^    hash = "/, ""); sub(/";$/, ""); print; exit } }' "$package_file"
}

current_jiti_version() {
  sed -n 's/^  jitiVersion = "\(.*\)";$/\1/p' "$package_file"
}

current_jiti_hash() {
  awk 'BEGIN { count = 0 } /^    hash = "/ { count++; if (count == 2) { sub(/^    hash = "/, ""); sub(/";$/, ""); print; exit } }' "$package_file"
}

current_typebox_version() {
  sed -n 's/^  typeboxVersion = "\(.*\)";$/\1/p' "$package_file"
}

current_typebox_hash() {
  awk 'BEGIN { count = 0 } /^    hash = "/ { count++; if (count == 3) { sub(/^    hash = "/, ""); sub(/";$/, ""); print; exit } }' "$package_file"
}

resolve_dependency_version() {
  local name=$1 range=$2
  npm view "$name@$range" version --json | node -e 'let data=""; process.stdin.on("data", c => data += c); process.stdin.on("end", () => { const value = JSON.parse(data); process.stdout.write(Array.isArray(value) ? String(value[value.length - 1] ?? "") : String(value ?? "")); });'
}

resolve_dependency_hash() {
  local name=$1 version=$2
  npm view "$name@$version" dist.integrity --json | tr -d '"'
}

write_package_nix() {
  local version=$1 rev=$2 hash=$3 jiti_version=$4 jiti_hash=$5 typebox_version=$6 typebox_hash=$7 tmp
  tmp=$(mktemp)

  jq -n \
    --arg version "$version" \
    --arg rev "$rev" \
    --arg hash "$hash" \
    --arg jitiVersion "$jiti_version" \
    --arg jitiHash "$jiti_hash" \
    --arg typeboxVersion "$typebox_version" \
    --arg typeboxHash "$typebox_hash" \
    '{ version: $version, rev: $rev, hash: $hash, jitiVersion: $jitiVersion, jitiHash: $jitiHash, typeboxVersion: $typeboxVersion, typeboxHash: $typeboxHash }' > "$tmp.json"

  jq -r '.version, .rev, .hash, .jitiVersion, .jitiHash, .typeboxVersion, .typeboxHash' < "$tmp.json" >/dev/null

  awk \
    -v version="$version" \
    -v rev="$rev" \
    -v hash="$hash" \
    -v jiti_version="$jiti_version" \
    -v jiti_hash="$jiti_hash" \
    -v typebox_version="$typebox_version" \
    -v typebox_hash="$typebox_hash" '
      BEGIN { hash_count = 0 }
      /^  version = "/ { print "  version = \"" version "\";"; next }
      /^    rev = "/ { print "    rev = \"" rev "\";"; next }
      /^  jitiVersion = "/ { print "  jitiVersion = \"" jiti_version "\";"; next }
      /^  typeboxVersion = "/ { print "  typeboxVersion = \"" typebox_version "\";"; next }
      /^    hash = "/ {
        hash_count++;
        if (hash_count == 1) {
          print "    hash = \"" hash "\";";
        } else if (hash_count == 2) {
          print "    hash = \"" jiti_hash "\";";
        } else if (hash_count == 3) {
          print "    hash = \"" typebox_hash "\";";
        } else {
          print;
        }
        next;
      }
      { print }
    ' "$package_file" > "$tmp"

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

old_version=$(current_version)
old_rev=$(current_rev)
old_hash=$(current_hash)
old_jiti_version=$(current_jiti_version)
old_jiti_hash=$(current_jiti_hash)
old_typebox_version=$(current_typebox_version)
old_typebox_hash=$(current_typebox_hash)
[[ -n "$old_version" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_rev" ]] || die "Failed to determine current rev from $package_file"
[[ -n "$old_hash" ]] || die "Failed to determine current source hash from $package_file"
[[ -n "$old_jiti_version" ]] || die "Failed to determine current jiti version from $package_file"
[[ -n "$old_jiti_hash" ]] || die "Failed to determine current jiti hash from $package_file"
[[ -n "$old_typebox_version" ]] || die "Failed to determine current typebox version from $package_file"
[[ -n "$old_typebox_hash" ]] || die "Failed to determine current typebox hash from $package_file"

release_json=$(latest_release_info)
new_version=$(jq -r '.version' <<< "$release_json")
new_rev=$(jq -r '.rev' <<< "$release_json")
new_tag=$(jq -r '.tag' <<< "$release_json")
[[ -n "$new_version" && "$new_version" != null ]] || die "Failed to determine latest version"
[[ -n "$new_rev" && "$new_rev" != null ]] || die "Failed to determine latest revision"
[[ -n "$new_tag" && "$new_tag" != null ]] || die "Failed to determine latest tag"

tmpdir=$(mktemp -d)
backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$new_tag.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
new_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$new_hash" && "$new_hash" != null ]] || die "Failed to determine source hash"

git clone --depth 1 --branch "$new_tag" "$repo_url" "$tmpdir/src" >/dev/null 2>&1

jiti_range=$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(p.dependencies?.jiti ?? "");' "$tmpdir/src/package.json")
typebox_range=$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(p.dependencies?.typebox ?? "");' "$tmpdir/src/package.json")
[[ -n "$jiti_range" ]] || die "Failed to determine jiti dependency range"
[[ -n "$typebox_range" ]] || die "Failed to determine typebox dependency range"

new_jiti_version=$(resolve_dependency_version jiti "$jiti_range")
new_jiti_hash=$(resolve_dependency_hash jiti "$new_jiti_version")
new_typebox_version=$(resolve_dependency_version typebox "$typebox_range")
new_typebox_hash=$(resolve_dependency_hash typebox "$new_typebox_version")
[[ -n "$new_jiti_version" ]] || die "Failed to determine jiti version"
[[ -n "$new_jiti_hash" ]] || die "Failed to determine jiti hash"
[[ -n "$new_typebox_version" ]] || die "Failed to determine typebox version"
[[ -n "$new_typebox_hash" ]] || die "Failed to determine typebox hash"

if [[ "$new_version" != "$old_version" || "$new_rev" != "$old_rev" || "$new_hash" != "$old_hash" || "$new_jiti_version" != "$old_jiti_version" || "$new_jiti_hash" != "$old_jiti_hash" || "$new_typebox_version" != "$old_typebox_version" || "$new_typebox_hash" != "$old_typebox_hash" ]]; then
  write_package_nix "$new_version" "$new_rev" "$new_hash" "$new_jiti_version" "$new_jiti_hash" "$new_typebox_version" "$new_typebox_hash"
fi

if [[ "$new_version" != "$old_version" ]]; then
  echo "Updated $package_file to $new_version ($new_tag)"
elif [[ "$new_rev" != "$old_rev" || "$new_hash" != "$old_hash" || "$new_jiti_version" != "$old_jiti_version" || "$new_jiti_hash" != "$old_jiti_hash" || "$new_typebox_version" != "$old_typebox_version" || "$new_typebox_hash" != "$old_typebox_hash" ]]; then
  echo "Updated package metadata for $new_version"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
