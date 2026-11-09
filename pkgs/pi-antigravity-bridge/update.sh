#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nodejs nixpkgs#nix -c bash
# shellcheck shell=bash
set -euo pipefail

# Follow main: the bridge and its two workspace libraries share a source pin.
# --check performs the update/dependency fetch, then restores the original files.
check=false
case "${1:-}" in
  "") ;;
  --check) check=true ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
repo_root=$(git rev-parse --show-toplevel)
repo_url=https://github.com/EstebanForge/pi-extensions.git
archive_base_url=https://github.com/EstebanForge/pi-extensions/archive
package_file=default.nix
tmpdir=$(mktemp -d)
cp "$package_file" "$tmpdir/default.nix"
cp package-lock.json "$tmpdir/package-lock.json"

cleanup() {
  local status=$?
  if (( status != 0 )) || "$check"; then
    cp "$tmpdir/default.nix" "$package_file"
    cp "$tmpdir/package-lock.json" package-lock.json
  fi
  rm -rf "$tmpdir"
  exit "$status"
}
trap cleanup EXIT
# Make cancellation enter cleanup with a failing status, even while Bash is
# waiting for a child command (where an unhandled signal can leave $? as zero).
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

rev=$(git ls-remote "$repo_url" HEAD | cut -f1)
[[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid upstream revision" >&2; exit 1; }
prefetch=$(nix store prefetch-file --json --unpack "$archive_base_url/$rev.tar.gz")
src=$(jq -er .storePath <<< "$prefetch")
hash=$(jq -er .hash <<< "$prefetch")
version=$(jq -er .version "$src/packages/pi-antigravity-bridge/package.json")

mkdir -p "$tmpdir/workspace/packages"
for name in pi-antigravity-bridge pi-ask-shared pi-tui-dialogs; do
  cp -r "$src/packages/$name" "$tmpdir/workspace/packages/"
done
chmod -R u+w "$tmpdir/workspace"
# Keep this minimal workspace manifest in sync with postPatch in default.nix.
jq '{name: "pi-antigravity-bridge-workspace", version: "1.0.0", private: true,
  workspaces: ["packages/pi-antigravity-bridge", "packages/pi-ask-shared", "packages/pi-tui-dialogs"]}' \
  "$src/package.json" > "$tmpdir/workspace/package.json"
cp package-lock.json "$tmpdir/workspace/"
(
  cd "$tmpdir/workspace"
  npm install --package-lock-only --ignore-scripts --legacy-peer-deps --no-audit --no-fund
)
cp "$tmpdir/workspace/package-lock.json" package-lock.json

awk -v version="$version" -v rev="$rev" -v hash="$hash" '
  /^  version = "/ { print "  version = \"" version "\";"; next }
  /^  rev = "/ { print "  rev = \"" rev "\";"; next }
  /^    hash = "/ { print "    hash = \"" hash "\";"; next }
  /^  npmDepsHash = / { print "  npmDepsHash = lib.fakeHash;"; next }
  { print }
' "$package_file" > "$tmpdir/updated.nix"
cp "$tmpdir/updated.nix" "$package_file"

# Use the locked flake's fetcher and its reported hash, not a global nixpkgs.
if nix build --option eval-cache false --no-link \
  "$repo_root#legacyPackages.x86_64-linux.pi-antigravity-bridge.npmDeps" \
  > "$tmpdir/build.log" 2>&1; then
  echo "Expected a dependency hash mismatch" >&2
  exit 1
fi
deps_hash=$(sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' "$tmpdir/build.log" | tail -n1)
if [[ -z "$deps_hash" ]]; then
  # Show the actual failure rather than leaving a fake hash behind.
  tail -n 80 "$tmpdir/build.log" >&2
  exit 1
fi
sed -i "s|^  npmDepsHash = lib.fakeHash;$|  npmDepsHash = \"$deps_hash\";|" "$package_file"

echo "Updated pi-antigravity-bridge to $version ($rev)"
if "$check"; then
  echo "Check complete; restoring package pins and lockfile"
fi
