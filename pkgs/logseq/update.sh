#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#python3 -c bash
# shellcheck shell=bash
# Update the source-built Logseq nightly and its fixed-output dependency hashes.
set -euo pipefail

repo_url=https://github.com/logseq/logseq.git
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
cp "$package_file" "$backup"
tmpdir=$(mktemp -d)
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

set_hash() {
  local field=$1 value=$2
  python3 - "$package_file" "$field" "$value" <<'PY'
import re
import sys

path, field, value = sys.argv[1:]
text = open(path).read()
if field == "clojureHome":
    pattern = re.compile(r'(?s)(  clojureHome = stdenv\.mkDerivation \{.*?    outputHash = ")[^"]+(")')
else:
    pattern = re.compile(rf'(?s)(  {re.escape(field)} = fetchPnpmDeps \{{.*?    hash = ")[^"]+(")')
text, count = pattern.subn(lambda m: m.group(1) + value + m.group(2), text, count=1)
if count != 1:
    raise SystemExit(f"could not update hash for {field} in {path}")
open(path, "w").write(text)
PY
}

set_git_source() {
  local field=$1 owner=$2 repo=$3 rev=$4 hash=$5
  python3 - "$package_file" "$field" "$owner" "$repo" "$rev" "$hash" <<'PY'
import re
import sys

path, field, owner, repo, rev, hash_ = sys.argv[1:]
text = open(path).read()
pattern = re.compile(
    rf'(?s)(    {re.escape(field)} = ocamlPackages\.buildDunePackage \{{.*?      src = fetchFromGitHub \{{)'
    r'\n        owner = "[^"]+";\n        repo = "[^"]+";\n        rev = "[^"]+";\n        hash = "[^"]+";(\n      \};)'
)
replacement = (
    rf'\1\n        owner = "{owner}";\n        repo = "{repo}";\n'
    rf'        rev = "{rev}";\n        hash = "{hash_}";\2'
)
text, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit(f"could not update source for {field} in {path}")
open(path, "w").write(text)
PY
}

prefetch_hash() {
  local owner=$1 repo=$2 rev=$3 json hash
  json=$(nix store prefetch-file --json --unpack "https://github.com/$owner/$repo/archive/$rev.tar.gz")
  hash=$(jq -r .hash <<<"$json")
  [[ "$hash" == sha256-* ]] || die "failed to prefetch $owner/$repo@$rev"
  printf '%s\n' "$hash"
}

refresh_pnpm_or_clojure_hash() {
  local field=$1 target=$2 log hash
  set_hash "$field" "$fake_hash"
  log="$tmpdir/$field.log"
  if (cd "$repo_root" && nix build --no-link --option eval-cache false ".#legacyPackages.x86_64-linux.logseq.$target") >"$log" 2>&1; then
    die "$field unexpectedly built with the placeholder hash"
  fi
  hash=$(sed -nE 's/.*got:[[:space:]]*(sha256-[A-Za-z0-9+/=]+).*/\1/p' "$log" | head -n1)
  if [[ "$hash" != sha256-* ]]; then
    cat "$log" >&2
    die "could not extract the corrected hash for $field"
  fi
  set_hash "$field" "$hash"
  echo "$field: $hash"
}

latest_rev=$(git ls-remote "$repo_url" HEAD | awk 'NR == 1 { print $1 }')
[[ "$latest_rev" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve upstream Logseq HEAD"
current_rev=$(sed -n 's/^  logseqRev = "\([^"]*\)";$/\1/p' "$package_file")
[[ -n "$current_rev" ]] || die "could not read logseqRev from $package_file"

if [[ "$latest_rev" == "$current_rev" ]]; then
  echo "Logseq is already pinned to upstream HEAD $latest_rev"
  exit 0
fi

echo "Updating Logseq source: $current_rev -> $latest_rev"
source_json=$(nix store prefetch-file --json --unpack "https://github.com/logseq/logseq/archive/$latest_rev.tar.gz")
source_hash=$(jq -r .hash <<<"$source_json")
source_path=$(jq -r .storePath <<<"$source_json")
[[ "$source_hash" == sha256-* && -d "$source_path" ]] || die "failed to prefetch Logseq source"
app_version=$(jq -r .version "$source_path/resources/package.json")
commit_date=$(curl -fsSL "https://api.github.com/repos/logseq/logseq/commits/$latest_rev" | jq -r '.commit.committer.date | split("T")[0] | gsub("-"; "")')
[[ "$app_version" != null && "$commit_date" =~ ^[0-9]{8}$ ]] || die "could not determine upstream version/date"
version="${app_version}-alpha+nightly.${commit_date}"
set_value logseqRev "$latest_rev"
set_value sourceHash "$source_hash"
set_value version "$version"

echo "Updating OCaml CLI git dependencies pinned by upstream opam metadata"
for dependency in \
  'humanize RCmerci humanize' \
  'melange-edn-melange logseq melange-edn' \
  'melange-transit-melange logseq melange-transit' \
  'rrbvec logseq rrbvec'; do
  read -r field owner repo <<<"$dependency"
  rev=$(git ls-remote "https://github.com/$owner/$repo.git" refs/heads/main | awk 'NR == 1 { print $1 }')
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve $owner/$repo main"
  hash=$(prefetch_hash "$owner" "$repo" "$rev")
  set_git_source "$field" "$owner" "$repo" "$rev" "$hash"
  echo "$field: $rev $hash"
done

refresh_pnpm_or_clojure_hash pnpmDeps pnpmDeps
refresh_pnpm_or_clojure_hash cliPnpmDeps cliPnpmDeps
refresh_pnpm_or_clojure_hash resourcesPnpmDeps resourcesPnpmDeps
refresh_pnpm_or_clojure_hash clojureHome clojureHome

(cd "$repo_root" && nix eval --option eval-cache false .#legacyPackages.x86_64-linux.logseq.drvPath >/dev/null)
echo "Updated Logseq to $version ($latest_rev)"
if [[ "$check_only" == true ]]; then
  echo "--check: validated the update; restored $package_file without keeping changes"
fi
