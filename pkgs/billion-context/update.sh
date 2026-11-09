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
# Create a temporary Nix expression to fetch the hash
github_hash=$(nix flake prefetch "github:ranxianglei/billion-context/v${version}" 2>&1 | tail -1)

echo "Updating default.nix..."
sed -i.bak \
  -e "s/version = \"[^\"]*\";/version = \"$version\";/" \
  -e "s|rev = \"v[^\"]*\";|rev = \"v${version}\";|" \
  -e "s|hash = \"sha256-[^\"]*\";|hash = \"${github_hash}\";|" \
  -e "s/npmSha512 = \"[^\"]*\";/npmSha512 = \"${sha512_base64}\";/" \
  default.nix

rm -f default.nix.bak

echo "Updated to version $version"
echo "GitHub source hash: $github_hash"
echo "npm tarball hash: $sha512_base64"
echo "Run: git diff default.nix"
