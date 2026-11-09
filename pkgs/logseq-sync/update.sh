#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#python3 -c bash
# shellcheck shell=bash
# Update the pinned Logseq sync integration and its npm dependency cache hash.
set -euo pipefail

repo_url=https://github.com/geml-spec/geml.git
package_file=default.nix
fake_hash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
check_only=false

if [[ ${1:-} == --check ]]; then
  check_only=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
cd "$script_dir"
backup=$(mktemp)
tmpdir=$(mktemp -d)
cp "$package_file" "$backup"
cleanup() {
  status=$?
  if [[ "$check_only" == true || $status -ne 0 ]]; then
    cp "$backup" "$package_file"
  fi
  rm -f "$backup"
  rm -rf "$tmpdir"
  exit "$status"
}
trap cleanup EXIT

die() { echo "$*" >&2; exit 1; }

set_value() {
  local key=$1 value=$2
  python3 - "$package_file" "$key" "$value" <<'PY'
import re
import sys

path, key, value = sys.argv[1:]
text = open(path).read()
pattern = re.compile(rf'(?m)^(  {re.escape(key)} = ")[^"]*(";)$')
text, count = pattern.subn(lambda m: m.group(1) + value + m.group(2), text, count=1)
if count != 1:
    raise SystemExit(f"could not update {key} in {path}")
open(path, "w").write(text)
PY
}

latest_rev=$(git ls-remote "$repo_url" refs/heads/main | awk 'NR == 1 { print $1 }')
[[ "$latest_rev" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve upstream geml main"
current_rev=$(sed -n 's/^  logseqRev = "\([^"]*\)";$/\1/p' "$package_file")
[[ -n "$current_rev" ]] || die "could not read logseqRev from $package_file"
if [[ "$latest_rev" == "$current_rev" ]]; then
  echo "logseq-sync is already pinned to upstream main $latest_rev"
  exit 0
fi

echo "Updating logseq-sync source: $current_rev -> $latest_rev"
source_json=$(nix store prefetch-file --json --unpack "https://github.com/geml-spec/geml/archive/$latest_rev.tar.gz")
source_hash=$(jq -r .hash <<<"$source_json")
source_path=$(jq -r .storePath <<<"$source_json")
[[ "$source_hash" == sha256-* && -d "$source_path" ]] || die "failed to prefetch geml source"
version=$(jq -r .version "$source_path/integrations/logseq/package.json")
[[ "$version" != null && -n "$version" ]] || die "could not read integration package version"
set_value version "$version"
set_value logseqRev "$latest_rev"
set_value sourceHash "$source_hash"
set_value npmDepsHash "$fake_hash"

log="$tmpdir/build.log"
if (cd "$repo_root" && nix build --no-link --option eval-cache false .#legacyPackages.x86_64-linux.logseq-sync) >"$log" 2>&1; then
  die "package unexpectedly built with the placeholder npmDepsHash"
fi
npm_deps_hash=$(sed -nE 's/.*got:[[:space:]]*(sha256-[A-Za-z0-9+/=]+).*/\1/p' "$log" | head -n1)
if [[ "$npm_deps_hash" != sha256-* ]]; then
  cat "$log" >&2
  die "could not extract the corrected npmDepsHash"
fi
set_value npmDepsHash "$npm_deps_hash"

(cd "$repo_root" && nix eval --option eval-cache false .#legacyPackages.x86_64-linux.logseq-sync.drvPath >/dev/null)
echo "Updated logseq-sync to $version ($latest_rev), npmDepsHash=$npm_deps_hash"
if [[ "$check_only" == true ]]; then
  echo "--check: validated the update; restored $package_file without keeping changes"
fi
