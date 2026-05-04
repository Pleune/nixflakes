#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#nodejs -c bash
# shellcheck shell=bash
set -euo pipefail

repo_owner=jayzeng
repo_name=pi-memory
repo_branch=main
archive_base_url=https://github.com/$repo_owner/$repo_name/archive
package_file=default.nix

die() { echo "$*" >&2; exit 1; }

latest_release_info() {
  local version rev

  # Upstream tags currently lag package.json, so follow the default branch metadata.
  version=$(
    node <<'NODE'
const https = require('https');
const url = 'https://raw.githubusercontent.com/jayzeng/pi-memory/main/package.json';
https.get(url, { headers: { 'User-Agent': 'nixflakes-update-script' } }, res => {
  let data = '';
  res.setEncoding('utf8');
  res.on('data', chunk => data += chunk);
  res.on('end', () => {
    if (res.statusCode && res.statusCode >= 400) {
      console.error(`Failed to fetch ${url}: HTTP ${res.statusCode}`);
      process.exit(1);
    }

    try {
      process.stdout.write(JSON.parse(data).version ?? '');
    } catch (error) {
      console.error(error.message);
      process.exit(1);
    }
  });
}).on('error', error => {
  console.error(error.message);
  process.exit(1);
});
NODE
  )
  rev=$(git ls-remote "https://github.com/$repo_owner/$repo_name" "refs/heads/$repo_branch" | awk '{print $1}')

  [[ -n "$version" ]] || die "Failed to determine latest version"
  [[ -n "$rev" ]] || die "Failed to determine latest gitHead"

  jq -n --arg version "$version" --arg gitHead "$rev" '{ version: $version, gitHead: $gitHead }'
}

current_version() {
  sed -n 's/^  version = "\(.*\)";$/\1/p' "$package_file"
}

current_rev() {
  sed -n 's/^  rev = "\(.*\)";$/\1/p' "$package_file"
}

current_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$package_file"
}

write_package_nix() {
  local version=$1 rev=$2 hash=$3 tmp
  tmp=$(mktemp)

  jq -n \
    --arg version "$version" \
    --arg rev "$rev" \
    --arg hash "$hash" \
    '{ version: $version, rev: $rev, hash: $hash }' > "$tmp.json"

  jq -r '.version, .rev, .hash' < "$tmp.json" >/dev/null

  sed \
    -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
    -e "s|^  rev = \".*\";$|  rev = \"${rev}\";|" \
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

old_version=$(current_version)
old_rev=$(current_rev)
old_hash=$(current_hash)
[[ -n "$old_version" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_rev" ]] || die "Failed to determine current rev from $package_file"
[[ -n "$old_hash" ]] || die "Failed to determine current hash from $package_file"

release_json=$(latest_release_info)
new_version=$(jq -r '.version' <<< "$release_json")
new_rev=$(jq -r '.gitHead' <<< "$release_json")
[[ -n "$new_version" && "$new_version" != null ]] || die "Failed to determine latest version"
[[ -n "$new_rev" && "$new_rev" != null ]] || die "Failed to determine latest gitHead"

tmpdir=$(mktemp -d)
backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$new_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
new_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$new_hash" && "$new_hash" != null ]] || die "Failed to determine source hash"

if [[ "$new_version" != "$old_version" || "$new_rev" != "$old_rev" || "$new_hash" != "$old_hash" ]]; then
  write_package_nix "$new_version" "$new_rev" "$new_hash"
fi

if [[ "$new_version" != "$old_version" ]]; then
  echo "Updated $package_file to $new_version ($new_rev)"
elif [[ "$new_rev" != "$old_rev" || "$new_hash" != "$old_hash" ]]; then
  echo "Updated source revision for $new_version"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
