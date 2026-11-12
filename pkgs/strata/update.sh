#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#nix nixpkgs#jq -c bash
# Update pkgs/strata/src.nix: bump Strata to a release tag (default: latest), re-read the
# llama.cpp pin Strata declares, and refresh both fetchFromGitHub hashes.
#
#   ./update.sh            # latest release
#   ./update.sh v0.2.14    # a specific tag
#
# Strata's third_party/ggml is a submodule, so its tarball carries only a VERSION.txt naming the
# llama.cpp rev the CMake build needs (Strata_GGML_DIR).  That rev is fetched as its own tarball,
# so a Strata bump usually also changes the pin - both are rewritten here.  engine.nix and
# vision.nix re-check the pin at build time, so a pin that drifted from VERSION.txt fails loudly.
#
# The Gyro model pins (HF revision, size, sha256) live in prefetch.py and are re-read from
# setup.py at the new tag too, so the two copies cannot drift apart silently.
#
# After running this: `git diff`, then
#   nix build --no-link .#packages.x86_64-linux.strata
#   nix build --no-link .#checks.x86_64-linux.strata-serve-smoke
#   nix build --no-link .#checks.x86_64-linux.strata-prefetch-gyro
#   nix build --no-link .#checks.x86_64-linux.strata-prefetch-vision
set -euo pipefail
cd "$(dirname "$0")"

OWNER="Niko1221"
REPO="Strata"
API="https://api.github.com/repos/$OWNER/$REPO"
SRC="src.nix"
# The SCA hash of an empty fixed-output derivation; used to make nix print the real one.
EMPTY="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# --- latest release tag ----------------------------------------------------
if [ $# -ge 1 ]; then
  TAG="$1"
else
  TAG=$(curl -fsSL "$API/releases/latest" | jq -r '.tag_name')
fi
if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "could not resolve a release tag" >&2
  exit 1
fi

# --- the llama.cpp rev Strata pins at that tag -----------------------------
# Read over the GitHub API, not from a store path: evaluating Strata's tree would be an
# import-from-derivation, which `nix flake check --no-build` forbids.
GGML=$(
  curl -fsSL "$API/contents/third_party/ggml/VERSION.txt?ref=$TAG" \
    | jq -r .content \
    | base64 -d \
    | cut -d' ' -f1
)
if [ -z "$GGML" ] || [ "$GGML" = "null" ]; then
  echo "could not read third_party/ggml/VERSION.txt at $TAG" >&2
  exit 1
fi

VERSION="${TAG#v}"

# --- hashes ----------------------------------------------------------------
hash_of() {
  local url="$1"
  local out
  out=$(nix-prefetch-url --unpack "$url" 2>&1 | tail -1)
  if ! printf '%s' "$out" | grep -Eq '^1[0-9a-z]{51}$'; then
    echo "nix-prefetch-url failed for $url: $out" >&2
    return 1
  fi
  nix hash convert --hash-algo sha256 --to base16 "$out" >/dev/null # validates the digest
  nix hash convert --hash-algo sha256 --to sca "$out"
}

STRATA_HASH=$(hash_of "https://github.com/$OWNER/$REPO/archive/$TAG.tar.gz")
GGML_HASH=$(hash_of "https://github.com/$OWNER/$REPO/archive/$GGML.tar.gz")

# --- rewrite ---------------------------------------------------------------
# Rewrite one `hash = "sha256-..."; // 1) ...` line inside a given fetchFromGitHub block.
set_hash() {
  local attr="$1" hash="$2"
  awk -v attr="$attr" -v hash="$hash" '
    $0 ~ "^  " attr " = " { inblock = 1 }
    inblock && /^    hash = / {
      sub(/hash = "[^"]*";.*/, "hash = \"" hash "\"; \/\/ 1) " hash)
      inblock = 0
    }
    { print }
  ' "$SRC" > "$SRC.tmp"
  # Fail if the block or its hash line was not found, rather than writing a half-patched file.
  grep -q "hash = \"$hash\";" "$SRC.tmp" || {
    echo "could not find the hash line for $attr in $SRC" >&2
    rm -f "$SRC.tmp"
    exit 1
  }
  mv "$SRC.tmp" "$SRC"
}

cp "$SRC" "$SRC.bak"
sed -i "s/^  version = \"[^\"]*\";/  version = \"$VERSION\";/" "$SRC"
sed -i "s/^  ggmlPin = \"[^\"]*\";/  ggmlPin = \"$GGML\";/" "$SRC"
sed -i "s/    rev = version; \/\/ 1) .*/    rev = version; \/\/ 1) $STRATA_HASH/" "$SRC"
sed -i "s/^    rev = \"[^\"]*\"; \/\/ 1) .*/    rev = \"$GGML\"; \/\/ 1) $GGML_HASH/" "$SRC"
set_hash strataSrc "$STRATA_HASH"
set_hash llamaSrc "$GGML_HASH"

# --- sync the gyro pins prefetch.py copies out of setup.py -----------------
# pkgs/strata/prefetch.py keeps its own copy of setup.py's Gyro tables (the HF revision the repo
# is read at, and each file's size + sha256).  Nothing in Nix evaluates setup.py, so without this
# a Strata bump leaves prefetch pointing at stale files, and the download fails on a sha mismatch
# at the worst possible moment - hours into a first start.  This re-reads the tables and rewrites
# them, then says what changed so the diff is reviewable.
SETUP=$(mktemp)
trap 'rm -f "$SETUP"' EXIT
curl -fsSL "https://raw.githubusercontent.com/$OWNER/$REPO/$TAG/setup.py" -o "$SETUP" || {
  echo "could not fetch setup.py at $TAG" >&2
  exit 1
}

GYRO_REV=$(grep -oE '"agentionai/Qwen3\.8-Flash-Next-Gyro-GGUF":\s*"[a-f0-9]{40}"' "$SETUP" |
  grep -oE '[a-f0-9]{40}' | head -1)
[ -n "$GYRO_REV" ] || { echo "no Gyro revision found in setup.py at $TAG" >&2; exit 1; }

sync_gyro() {
  local key="$1" file="$2"
  # setup.py's entry looks like: "<file>": (58487015808, "c6ea..."),  possibly split over lines.
  local pair
  pair=$(tr -d '\n' < "$SETUP" | grep -oE "\"$file\": \([0-9]+,[[:space:]]*\"[a-f0-9]{64}\"" | head -1)
  [ -n "$pair" ] || { echo "no GYRO_FILES entry for $file in setup.py at $TAG" >&2; exit 1; }
  local bytes sha
  bytes=$(grep -oE '\([0-9]+' <<< "$pair" | tr -d '(')
  sha=$(grep -oE '[a-f0-9]{64}' <<< "$pair" | head -1)

  # Rewrite the two pins inside that quant's block in prefetch.py.  The block is found by the
  # dict key (`"Gyro-M": {`), not by the bare name: `"quants": ("Gyro-S", "Gyro-M")` also
  # mentions it, and anchoring on the key stops that line from swallowing the previous block.
  awk -v name="$key" -v sha="$sha" -v bytes="$bytes" '
    index($0, "\"" name "\": {") { inblock = 1 }
    inblock && /"bytes":/ { sub(/"bytes": [0-9]+/, "\"bytes\": " bytes) }
    inblock && /"sha256":/ { sub(/"sha256": "[a-f0-9]+"/, "\"sha256\": \"" sha "\""); inblock = 0 }
    { print }
  ' prefetch.py > prefetch.py.tmp
  grep -q "\"sha256\": \"$sha\"" prefetch.py.tmp || {
    echo "could not find the sha256 line for $key in prefetch.py" >&2
    rm -f prefetch.py.tmp
    exit 1
  }
  mv prefetch.py.tmp prefetch.py
  echo "  $key: $file $bytes bytes $sha"
}

# The revision the gyro family's base URL resolves.
sed -i "s#Qwen3.8-Flash-Next-Gyro-GGUF/resolve/[a-f0-9]\{40\}#Qwen3.8-Flash-Next-Gyro-GGUF/resolve/$GYRO_REV#" prefetch.py

echo "gyro pins synced to $TAG:"
sync_gyro Gyro-S 'Qwen3\.8-Flash-Next-Gyro-S-TQ1_0\.gguf'
sync_gyro Gyro-M 'Qwen3\.8-Flash-Next-Gyro-M-TQ2_0\.gguf'

echo "updated $SRC: Strata $VERSION, ggml $GGML"
echo "backup at $SRC.bak - remove it once the diff looks right"
echo "then: git diff -- $SRC prefetch.py && nix build --no-link .#packages.x86_64-linux.strata"
echo "and:  nix build --no-link .#checks.x86_64-linux.prefetch-gyro   # checks the synced shas"
