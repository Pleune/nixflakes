#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/Whamp/pi-token-burden.git
archive_base_url=https://github.com/Whamp/pi-token-burden/archive/refs/tags
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

current_hash() {
  awk 'BEGIN { count = 0 } /^    hash = "/ { count++; if (count == 1) { sub(/^    hash = "/, ""); sub(/";$/, ""); print; exit } }' "$package_file"
}

current_pnpm_deps_hash() {
  awk 'BEGIN { count = 0 } /^    hash = "/ { count++; if (count == 2) { sub(/^    hash = "/, ""); sub(/";$/, ""); print; exit } }' "$package_file"
}

write_package_nix() {
  local version=$1 hash=$2 pnpm_deps_hash=$3 tmp
  tmp=$(mktemp)

  jq -n \
    --arg version "$version" \
    --arg hash "$hash" \
    --arg pnpmDepsHash "$pnpm_deps_hash" \
    '{ version: $version, hash: $hash, pnpmDepsHash: $pnpmDepsHash }' > "$tmp.json"

  jq -r '.version, .hash, .pnpmDepsHash' < "$tmp.json" >/dev/null

  awk \
    -v version="$version" \
    -v hash="$hash" \
    -v pnpm_deps_hash="$pnpm_deps_hash" '
      BEGIN { hash_count = 0 }
      /^  version = "/ { print "  version = \"" version "\";"; next }
      /^    hash = "/ {
        hash_count++;
        if (hash_count == 1) {
          print "    hash = \"" hash "\";";
        } else if (hash_count == 2) {
          print "    hash = \"" pnpm_deps_hash "\";";
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

old_hash=$(current_hash)
old_pnpm_deps_hash=$(current_pnpm_deps_hash)
current_rev=$(current_rev)
[[ -n "$current_rev" ]] || die "Failed to determine current version from $package_file"
[[ -n "$old_hash" ]] || die "Failed to determine current source hash from $package_file"
[[ -n "$old_pnpm_deps_hash" ]] || die "Failed to determine current pnpm deps hash from $package_file"

latest_rev=$(latest_tag)
[[ -n "$latest_rev" ]] || die "Failed to determine latest upstream tag"

target_rev=$current_rev
version_changed=false
if [[ "$latest_rev" != "$current_rev" ]]; then
  target_rev=$latest_rev
  version_changed=true
fi

backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$target_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
src_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$src_hash" && "$src_hash" != null ]] || die "Failed to determine source hash"

pnpm_deps_hash=$(
  {
    nix build --impure --expr "
      let
        flake = builtins.getFlake (toString ../..);
        pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; config.allowUnfree = true; };
        src = pkgs.fetchFromGitHub {
          owner = \"Whamp\";
          repo = \"pi-token-burden\";
          rev = \"$target_rev\";
          hash = \"$src_hash\";
        };
      in pkgs.fetchPnpmDeps {
        pname = \"pi-token-burden\";
        version = \"${target_rev#v}\";
        inherit src;
        pnpm = pkgs.pnpm_10;
        fetcherVersion = 3;
        pnpmInstallFlags = [ \"--prod\" ];
        hash = \"\";
      }
    " --no-link 2>&1 >/dev/null || true
  } | sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | tail -n1
)
[[ -n "$pnpm_deps_hash" ]] || die "Failed to determine pnpm deps hash"

if [[ "$version_changed" == "true" || "$src_hash" != "$old_hash" || "$pnpm_deps_hash" != "$old_pnpm_deps_hash" ]]; then
  write_package_nix "${target_rev#v}" "$src_hash" "$pnpm_deps_hash"
fi

if [[ "$version_changed" == "true" ]]; then
  echo "Updated $package_file to $target_rev"
elif [[ "$src_hash" != "$old_hash" || "$pnpm_deps_hash" != "$old_pnpm_deps_hash" ]]; then
  echo "Updated package metadata for $target_rev"
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
