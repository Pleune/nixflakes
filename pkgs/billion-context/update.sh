#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq -c bash
# shellcheck shell=bash
set -euo pipefail

cd "$(dirname "$0")"

# Fetch latest version from npm registry
echo "Fetching latest billion-context version..."
version=$(curl -s https://registry.npmjs.org/billion-context | jq -r '.["dist-tags"].latest')
echo "Latest version: $version"

# Get npm tarball SHA512
echo "Fetching tarball integrity hash..."
integrity=$(curl -s "https://registry.npmjs.org/billion-context/$version" | jq -r '.dist.integrity')

# Convert npm integrity format (sha512-...) to the format we need (just base64 part)
sha512_base64="${integrity#sha512-}"

# Get GitHub source hash
echo "Fetching GitHub source hash for v${version}..."
# Ask Nix for the locked hash via JSON so warning/status lines can never leak
# into the replacement string.
github_hash=$(nix flake prefetch --json "github:ranxianglei/billion-context/v${version}" 2>/dev/null |
  jq -r '(if type == "array" then .[0] else . end) | .hash')
[[ -n "$github_hash" && "$github_hash" != null ]] || {
  echo "Failed to determine GitHub source hash" >&2
  exit 1
}

echo "Updating default.nix..."
sed -i.bak \
  -e "s/version = \"[^\"]*\";/version = \"$version\";/" \
  -e "s|rev = \"v[^\"]*\";|rev = \"v${version}\";|" \
  -e "s|hash = \"sha256-[^\"]*\";|hash = \"${github_hash}\";|" \
  -e "s|npmSha512 = \"[^\"]*\";|npmSha512 = \"${sha512_base64}\";|" \
  default.nix

rm -f default.nix.bak

echo "Updated to version $version"
echo "GitHub source hash: $github_hash"
echo "npm tarball hash: $sha512_base64"
echo "Run: git diff default.nix"
