#!/usr/bin/env bash
# Exercises deploy-ai's scope guard without root, a VM, or a switch: it builds a baseline tree, a
# candidate tree, and an allowlist in a temp dir, then checks that an in-scope change is accepted
# and an out-of-scope one is refused.  Run with: bash pkgs/deploy-ai/test-scope.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BASELINE=$WORK/baseline
CANDIDATE=$WORK/candidate
export DEPLOY_AI_GUEST_CANDIDATE=$CANDIDATE
export DEPLOY_AI_BASELINE=$BASELINE
export DEPLOY_AI_ALLOWLIST=$WORK/allowlist
export DEPLOY_AI_STATE=$WORK/state

# The allowlist the ai platform ships, minus the prefixes this fixture does not reproduce.
cat > "$DEPLOY_AI_ALLOWLIST" <<'EOF'
# comment line, ignored
platforms/ai.nix
platforms/buildvm.nix
lib/
modules/nixos/
config/
pkgs/
flake.nix
README.md
EOF

mkdir -p "$BASELINE"/{platforms,lib,modules/nixos,config/secrets,docs} "$CANDIDATE"/{platforms,lib,modules/nixos,config/secrets,docs}
for tree in "$BASELINE" "$CANDIDATE"; do
  printf 'system\n' > "$tree/platforms/ai.nix"
  printf 'shared\n' > "$tree/platforms/buildvm.nix"
  printf 'helper\n' > "$tree/lib/buildvm.nix"
  printf 'module\n' > "$tree/modules/nixos/deploy-ai.nix"
  printf 'doc\n' > "$tree/docs/hermes-agent-flake-deploy.md"
  printf 'readme\n' > "$tree/README.md"
  printf 'lock\n' > "$tree/flake.lock"
  printf 'flake\n' > "$tree/flake.nix"
done

source "$HERE/deploy-ai.sh"

expect_ok() {
  if check_scope "$CANDIDATE"; then
    echo "ok: $1"
  else
    echo "FAIL: $1 should have been accepted" >&2
    exit 1
  fi
}

expect_refused() {
  local pattern=$2
  local out
  # deploy-ai's refusal exits, and bash hands the EXIT trap to subshells, so clear it here or the
  # temp fixture would be deleted mid-test.
  if out=$(trap - EXIT; check_scope "$CANDIDATE" 2>&1); then
    echo "FAIL: $1 should have been refused" >&2
    exit 1
  fi
  printf '%s\n' "$out" | grep -q "$pattern" || {
    echo "FAIL: $1 refused for the wrong reason; output was:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  echo "ok: $1"
}

# Identical trees: nothing changed, nothing to refuse.
expect_ok "identical trees pass"

# An in-scope edit and an in-scope new file.
mkdir -p "$CANDIDATE/lib/buildvm"
printf 'changed\n' > "$CANDIDATE/platforms/ai.nix"
printf 'new\n' > "$CANDIDATE/lib/buildvm/extra.nix"
printf 'new readme line\n' >> "$CANDIDATE/README.md"
expect_ok "edited platforms/ai.nix, added lib/buildvm/extra.nix, edited README.md pass"

# A new file in a directory no allowlist entry covers.
mkdir -p "$CANDIDATE/nixosModules/evil"
printf 'bad\n' > "$CANDIDATE/nixosModules/evil/default.nix"
expect_refused "new nixosModules/ tree refused" "refusing: .nixosModules. is outside"

# A top-level file nobody may touch.
rm -rf "$CANDIDATE/nixosModules"
printf 'bad\n' > "$CANDIDATE/machines.sh"
expect_refused "new top-level machines.sh refused" "machines.sh"
rm "$CANDIDATE/machines.sh"

# A deleted in-scope file is a scope-relevant change, and still allowed here.
rm "$BASELINE/lib/buildvm.nix" "$CANDIDATE/lib/buildvm.nix"
expect_ok "removing an in-scope file passes"

# Deleting something outside the allowlist is refused too: dropping files is as dangerous as adding.
rm "$BASELINE/docs/hermes-agent-flake-deploy.md"
expect_refused "deleting docs/ outside the allowlist refused" "refusing: .docs/hermes-agent-flake-deploy.md. is outside"

# in_scope() itself: prefix entries vs exact-file entries.
in_scope "lib/x.nix" || { echo "FAIL: lib/ should match lib/x.nix" >&2; exit 1; }
in_scope "flake.nix" || { echo "FAIL: flake.nix should match itself" >&2; exit 1; }
in_scope "flake.nix.lock" && { echo "FAIL: exact-file entry must not prefix-match" >&2; exit 1; }
in_scope "platforms/ai.nix.bak" && { echo "FAIL: platforms/ai.nix must not match ai.nix.bak" >&2; exit 1; }
echo "ok: in_scope matches prefixes and exact files, not near-misses"

# changed_paths() reports bare repo-relative paths, including at the top level.
printf 'bad\n' > "$CANDIDATE/machines.sh"
paths=$(changed_paths "$CANDIDATE")
printf '%s\n' "$paths" | grep -qx 'machines.sh' || {
  echo "FAIL: changed_paths should list top-level machines.sh; got:" >&2
  printf '%s\n' "$paths" >&2
  exit 1
}
printf '%s\n' "$paths" | grep -qx 'docs/hermes-agent-flake-deploy.md' || {
  echo "FAIL: changed_paths should list the docs/ deletion" >&2
  exit 1
}
echo "ok: changed_paths emits repo-relative paths"

echo "deploy-ai scope guard: all checks passed"
