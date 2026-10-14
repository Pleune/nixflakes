#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#nodejs -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/Rahularya01/pi-antigravity.git
archive_base_url=https://github.com/Rahularya01/pi-antigravity/archive/refs/tags
npm_package=undici
package_file=default.nix

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

current_src_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$package_file" | sed -n '1p'
}

current_undici_version() {
  sed -n 's/^  undiciVersion = "\(.*\)";$/\1/p' "$package_file"
}

current_undici_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$package_file" | sed -n '2p'
}

upstream_undici_version() {
  local rev=$1
  node - "$rev" <<'NODE'
const https = require('https');
const rev = process.argv[2];
const url = `https://raw.githubusercontent.com/Rahularya01/pi-antigravity/${rev}/package.json`;
https.get(url, { headers: { 'User-Agent': 'nixflakes-update-script' } }, res => {
  let data = '';
  res.setEncoding('utf8');
  res.on('data', chunk => data += chunk);
  res.on('end', () => {
    if ((res.statusCode ?? 0) >= 400) {
      console.error(`Failed to fetch ${url}: HTTP ${res.statusCode}`);
      process.exit(1);
    }

    try {
      const pkg = JSON.parse(data);
      const spec = pkg.dependencies?.undici;
      if (typeof spec !== 'string') {
        throw new Error('undici dependency not found');
      }
      const match = spec.match(/^[~^]?(.+)$/);
      if (!match) {
        throw new Error(`unsupported undici version spec: ${spec}`);
      }
      process.stdout.write(match[1]);
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
}

write_package_nix() {
  local version=$1 src_hash=$2 undici_version=$3 undici_hash=$4

  jq -n \
    --arg version "$version" \
    --arg src_hash "$src_hash" \
    --arg undici_version "$undici_version" \
    --arg undici_hash "$undici_hash" \
    '{ version: $version, src_hash: $src_hash, undici_version: $undici_version, undici_hash: $undici_hash }' > update.json

  jq -r '.version, .src_hash, .undici_version, .undici_hash' < update.json >/dev/null

  node - "$package_file" update.json <<'NODE'
const fs = require('fs');
const packageFile = process.argv[2];
const updateFile = process.argv[3];
const updates = JSON.parse(fs.readFileSync(updateFile, 'utf8'));
let text = fs.readFileSync(packageFile, 'utf8');

text = text.replace(/(^  version = ").*(";\n)/m, `$1${updates.version}$2`);
text = text.replace(/(^  undiciVersion = ").*(";\n)/m, `$1${updates.undici_version}$2`);
text = text.replace(/(undiciSrc = fetchurl \{[\s\S]*?^    hash = ").*(";\n  \};)/m, `$1${updates.undici_hash}$2`);
text = text.replace(/(src = fetchFromGitHub \{[\s\S]*?^    hash = ").*(";\n  \};)/m, `$1${updates.src_hash}$2`);

fs.writeFileSync(packageFile, text);
NODE

  rm -f update.json
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

old_rev=$(current_rev)
old_src_hash=$(current_src_hash)
old_undici_version=$(current_undici_version)
old_undici_hash=$(current_undici_hash)
[[ -n "$old_rev" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_src_hash" ]] || die "Failed to determine current source hash from $package_file"
[[ -n "$old_undici_version" ]] || die "Failed to determine current undici version from $package_file"
[[ -n "$old_undici_hash" ]] || die "Failed to determine current undici hash from $package_file"

new_rev=$(latest_tag)
[[ -n "$new_rev" ]] || die "Failed to determine latest upstream tag"

new_undici_version=$(upstream_undici_version "$new_rev")
[[ -n "$new_undici_version" ]] || die "Failed to determine upstream undici version"

tmpdir=$(mktemp -d)
backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

prefetch_json=$(nix store prefetch-file --json --unpack "$archive_base_url/$new_rev.tar.gz")
new_src_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$new_src_hash" && "$new_src_hash" != null ]] || die "Failed to determine source hash"

undici_prefetch_json=$(nix store prefetch-file --json "https://registry.npmjs.org/$npm_package/-/$npm_package-$new_undici_version.tgz")
new_undici_hash=$(jq -r .hash <<< "$undici_prefetch_json")
[[ -n "$new_undici_hash" && "$new_undici_hash" != null ]] || die "Failed to determine undici hash"

if [[ "$new_rev" != "$old_rev" || "$new_src_hash" != "$old_src_hash" || "$new_undici_version" != "$old_undici_version" || "$new_undici_hash" != "$old_undici_hash" ]]; then
  write_package_nix "${new_rev#v}" "$new_src_hash" "$new_undici_version" "$new_undici_hash"
fi

if [[ "$new_rev" != "$old_rev" ]]; then
  echo "Updated $package_file to $new_rev"
elif [[ "$new_src_hash" != "$old_src_hash" || "$new_undici_version" != "$old_undici_version" || "$new_undici_hash" != "$old_undici_hash" ]]; then
  echo "Updated package metadata for $new_rev"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
