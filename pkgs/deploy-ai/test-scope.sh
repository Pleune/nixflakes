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
export DEPLOY_AI_DENY_FILE=$WORK/denylist
export DEPLOY_AI_GUEST_ONLY_FILE=$WORK/guest-only-paths
export DEPLOY_AI_POLICY_FILE=$WORK/policy-digest
export DEPLOY_AI_SUBMIT_MAX_BYTES_FILE=$WORK/submit-max-bytes
export DEPLOY_AI_INBOX=$WORK/inbox
export DEPLOY_AI_RECORDED_GUEST_COMMIT=$WORK/state/guest-commit
export DEPLOY_AI_GUEST_REPO=$WORK/guest-repo
export DEPLOY_AI_BASELINE_COMMIT=$WORK/deployed-commit

# The commit the fixture's baseline came from, so baseline_commit() has something to read.
DEPLOYED_SHA=1111111111111111111111111111111111111111
printf '%s\n' "$DEPLOYED_SHA" > "$DEPLOY_AI_BASELINE_COMMIT"

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

# A tree shaped like the flake, with one file per allowlist area.  Rebuilt from scratch for the
# submit tests, since the scope tests below mutate both trees.
seed_tree() {
  local tree=$1
  mkdir -p "$tree"/{platforms,lib,modules/nixos/deploy-ai,pkgs/deploy-ai,config/secrets,docs}
  printf 'system\n' > "$tree/platforms/ai.nix"
  printf 'shared\n' > "$tree/platforms/buildvm.nix"
  printf 'helper\n' > "$tree/lib/buildvm.nix"
  printf 'module\n' > "$tree/modules/nixos/deploy-ai/default.nix"
  printf 'script\n' > "$tree/pkgs/deploy-ai/deploy-ai.sh"
  printf 'doc\n' > "$tree/docs/hermes-agent-flake-deploy.md"
  printf 'readme\n' > "$tree/README.md"
  printf 'lock\n' > "$tree/flake.lock"
  printf 'flake\n' > "$tree/flake.nix"
}
mkdir -p "$BASELINE" "$CANDIDATE"
seed_tree "$BASELINE"
seed_tree "$CANDIDATE"

# The lists and the cap the submit path reads, in the shapes the NixOS module installs them.
cat > "$DEPLOY_AI_GUEST_ONLY_FILE" <<'EOF'
# comment line, ignored
platforms/buildvm.nix
lib/buildvm.nix
modules/nixos/buildvm/
config/buildvm/
EOF

# Prefix entries plus an exact-file entry, matching nixflakes.deploy-ai.submit.denylist.
cat > "$DEPLOY_AI_DENY_FILE" <<'EOF'
# the gate cannot vet a change to itself
modules/nixos/deploy-ai/
pkgs/deploy-ai/
flake.lock
secrets/
EOF

printf '%s\n' 0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0 > "$DEPLOY_AI_POLICY_FILE"
printf '%s\n' 4096 > "$DEPLOY_AI_SUBMIT_MAX_BYTES_FILE"

source "$HERE/deploy-ai.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

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

# ------------------------------------------------------------------ submit guards

# The same two expectations for the submit functions, which take the list file and the tree as
# arguments.  A refusal exits, and bash hands the EXIT trap to subshells, so it is cleared inside
# the capture or the fixture would be deleted mid-test.
expect_ok_cmd() {
  local name=$1
  shift
  if (trap - EXIT; "$@" > /dev/null 2>&1); then
    echo "ok: $name"
  else
    echo "FAIL: $name should have succeeded" >&2
    (trap - EXIT; "$@" 2>&1 | tail -n 20) >&2
    exit 1
  fi
}

expect_refused_cmd() {
  local name=$1 pattern=$2
  shift 2
  local out
  if out=$(trap - EXIT; "$@" 2>&1); then
    echo "FAIL: $name should have been refused" >&2
    exit 1
  fi
  printf '%s\n' "$out" | grep -q "$pattern" || {
    echo "FAIL: $name refused for the wrong reason; output was:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  echo "ok: $name"
}

# baseline_commit(): the recorded commit, the dirty-tree suffix, and the absence of either.
[ "$(trap - EXIT; baseline_commit 2>/dev/null)" = "$DEPLOYED_SHA" ] \
  || fail "baseline_commit should read $DEPLOY_AI_BASELINE_COMMIT"
printf '%s-dirty\n' "$DEPLOYED_SHA" > "$DEPLOY_AI_BASELINE_COMMIT"
out=$(trap - EXIT; baseline_commit 2>&1)
printf '%s\n' "$out" | grep -q 'dirty tree; checking against' \
  || fail "a '<rev>-dirty' baseline should still compare against the commit; output was: $out"
printf '%s\n' "$out" | grep -q "$DEPLOYED_SHA" || fail "the dirty note should name $DEPLOYED_SHA"
printf '%s\n' "$DEPLOYED_SHA" > "$DEPLOY_AI_BASELINE_COMMIT"
echo "ok: baseline_commit reads the recorded commit, dirty suffix included"
rm "$DEPLOY_AI_BASELINE_COMMIT"
expect_refused_cmd "no baseline commit recorded refuses" "no baseline commit recorded" baseline_commit
printf '%s\n' "$DEPLOYED_SHA" > "$DEPLOY_AI_BASELINE_COMMIT"

# matches_path(): the same entry shapes as in_scope(), against an arbitrary list file.
matches_path platforms/buildvm.nix "$DEPLOY_AI_GUEST_ONLY_FILE" \
  || fail "platforms/buildvm.nix is a guest-only exact-file entry"
matches_path lib/buildvm.nix "$DEPLOY_AI_GUEST_ONLY_FILE" || fail "lib/buildvm.nix is guest-only"
matches_path modules/nixos/buildvm/default.nix "$DEPLOY_AI_GUEST_ONLY_FILE" \
  || fail "modules/nixos/buildvm/ should cover everything under it"
matches_path platforms/buildvm.nix.bak "$DEPLOY_AI_GUEST_ONLY_FILE" && fail "exact-file entry must not prefix-match"
matches_path platforms/ai.nix "$DEPLOY_AI_GUEST_ONLY_FILE" && fail "platforms/ai.nix is not guest-only"
echo "ok: matches_path matches prefixes and exact files, not near-misses"

# A fresh pair of trees: the scope tests above mutated $BASELINE and $CANDIDATE.
rm -rf "$BASELINE" "$CANDIDATE"
seed_tree "$BASELINE"
seed_tree "$CANDIDATE"

# classify_changes(): guest-only paths alone switch the VM, anything else reaches ai.
printf 'shared v2\n' > "$CANDIDATE/platforms/buildvm.nix"
[ "$(trap - EXIT; classify_changes "$CANDIDATE")" = guest ] \
  || fail "a change to platforms/buildvm.nix alone should classify as guest"
printf 'system v2\n' > "$CANDIDATE/platforms/ai.nix"
[ "$(trap - EXIT; classify_changes "$CANDIDATE")" = ai ] \
  || fail "a change outside the guest-only paths should classify as ai"
printf 'shared\n' > "$CANDIDATE/platforms/buildvm.nix"
rm "$CANDIDATE/platforms/ai.nix"
echo "ok: classify_changes splits guest-only from host-reaching changes"

# check_deny(): the gate's own machinery, by prefix and by exact file.
printf 'patched\n' > "$CANDIDATE/modules/nixos/deploy-ai/default.nix"
expect_refused_cmd "edit under modules/nixos/deploy-ai/ refused" "on the deploy-ai denylist" check_deny "$CANDIDATE"
# Back to baseline content: an empty directory left behind would still read as a removal.
printf 'module\n' > "$CANDIDATE/modules/nixos/deploy-ai/default.nix"
printf 'locked v2\n' > "$CANDIDATE/flake.lock"
expect_refused_cmd "edit of flake.lock refused" "flake.lock. is on the deploy-ai denylist" check_deny "$CANDIDATE"
printf 'lock\n' > "$CANDIDATE/flake.lock"
expect_ok_cmd "check_deny accepts a guest-only change" check_deny "$CANDIDATE"

# check_policy(): the digest evaluated from the patched tree must be the one ai already enforces.
expect_ok_cmd "check_policy accepts the recorded digest" check_policy "$(head -n 1 "$DEPLOY_AI_POLICY_FILE")"
expect_refused_cmd "check_policy refuses a moved digest" "changes the deployment policy" \
  check_policy 0000000000000000000000000000000000000000000000000000000000000000

# ------------------------------------------------------------------ the inbox cap

# The cap is read out of the file when the script is sourced, not hardcoded.
[ "$SUBMIT_MAX_BYTES" = 4096 ] \
  || fail "SUBMIT_MAX_BYTES should be 4096 from $DEPLOY_AI_SUBMIT_MAX_BYTES_FILE, got '$SUBMIT_MAX_BYTES'"

inbox_count() {
  local n=0 f
  # The inbox does not exist until the first submission creates it.
  for f in "$DEPLOY_AI_INBOX"/*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

before=$(inbox_count)
record=$(trap - EXIT; printf 'From: patch\n' | save_incoming_patch 2>/dev/null) \
  || fail "a small patch should be accepted"
case $record in
  "$DEPLOY_AI_INBOX/"*.patch) ;;
  *) fail "the submission should be recorded in $DEPLOY_AI_INBOX, got '$record'" ;;
esac
[ "$(cat "$record")" = "From: patch" ] || fail "the recorded file should hold the submission verbatim"
[ "$(stat -c %a "$record")" = 600 ] || fail "the recorded file should be 600, got $(stat -c %a "$record")"
[ "$(inbox_count)" = "$((before + 1))" ] || fail "each submission should leave its own record"
echo "ok: save_incoming_patch records the submission in the inbox as 0600"

# The size in the message is the read length, not the submission's length: the cap is enforced by
# reading one byte past it, so the whole submission is never buffered.
head -c 5000 /dev/zero > "$WORK/oversized.patch"
if out=$(trap - EXIT; save_incoming_patch < "$WORK/oversized.patch" 2>&1); then
  fail "a patch over the cap should be refused"
fi
printf '%s\n' "$out" | grep -q "patch too large: 4097 bytes, over the 4096 limit in $DEPLOY_AI_SUBMIT_MAX_BYTES_FILE" \
  || { echo "FAIL: oversized patch refused for the wrong reason; output was:" >&2; printf '%s\n' "$out" >&2; exit 1; }
# The refused submission stays as the record of what arrived.  One process reuses one record name
# (<utc timestamp>-<pid>.patch), so the count does not grow here; two real invocations are two
# processes, and the lock keeps them apart.
latest=$(printf '%s\n' "$DEPLOY_AI_INBOX"/*.patch | tail -n 1)
[ "$(wc -c < "$latest")" = 4097 ] \
  || fail "the refused submission should be kept as the record; $latest holds $(wc -c < "$latest") bytes"
echo "ok: an oversized submission is refused by size and kept as the record"

if out=$(trap - EXIT; : | save_incoming_patch 2>&1); then
  fail "empty stdin should be refused"
fi
printf '%s\n' "$out" | grep -q 'empty patch on stdin' \
  || { echo "FAIL: empty stdin refused for the wrong reason; output was:" >&2; printf '%s\n' "$out" >&2; exit 1; }
echo "ok: an empty submission is refused"

# A cap file nobody wrote an integer into is a refusal, not an uncapped read from the guest.
cap_saved=$SUBMIT_MAX_BYTES
SUBMIT_MAX_BYTES=4096k
if out=$(trap - EXIT; printf 'x\n' | save_incoming_patch 2>&1); then
  fail "a non-integer cap should be refused"
fi
printf '%s\n' "$out" | grep -q "does not hold an integer: '4096k'" \
  || { echo "FAIL: non-integer cap refused for the wrong reason; output was:" >&2; printf '%s\n' "$out" >&2; exit 1; }
SUBMIT_MAX_BYTES=$cap_saved
echo "ok: a non-integer cap in $DEPLOY_AI_SUBMIT_MAX_BYTES_FILE is refused"
rm -f "$WORK/oversized.patch"

# ------------------------------------------------------------------ reconstruction

# A real series, generated the way the guest generates one.
SRC=$WORK/patch-src
mkdir -p "$SRC"
tar -C "$BASELINE" -cf - . | tar -x -C "$SRC"
git -C "$SRC" init --quiet
commit_src() {
  git -C "$SRC" add -A
  git -C "$SRC" -c user.name=test -c user.email=test@example.com commit --quiet -m "$1"
}
commit_src "fixture base"
printf 'shared v2\n' > "$SRC/platforms/buildvm.nix"
commit_src "guest-only change"
git -C "$SRC" format-patch --stdout HEAD~1 > "$WORK/series.patch"

DEST=$WORK/rebuilt
mkdir -p "$DEST"
reconstruct_tree "$WORK/series.patch" "$DEST" "$DEPLOYED_SHA"
[ "$(cat "$DEST/platforms/buildvm.nix")" = "shared v2" ] || fail "the patch should be applied to ai's baseline"
[ "$(git -C "$DEST" rev-list --count HEAD)" = 1 ] \
  || fail "the reconstructed tree should carry one host-authored commit"
[ "$SHA" = "$(git -C "$DEST" rev-parse HEAD)" ] || fail "reconstruct_tree should set SHA to the reconstructed commit"
[ -d "$DEST/.git" ] || fail "the reconstructed tree needs a git dir for git apply"
echo "ok: reconstruct_tree rebuilds ai's baseline plus the series as one host commit"

# A patch whose context is not the deployed tree: `git apply --check` refuses before anything is
# written, so the copy of the baseline stays untouched.
git -C "$SRC" checkout --quiet HEAD~1 -- platforms/buildvm.nix
printf 'a different baseline\n' > "$SRC/platforms/buildvm.nix"
commit_src "diverged from the deployed tree"
git -C "$SRC" format-patch -1 HEAD --stdout > "$WORK/stale.patch"
STALE=$WORK/stale
mkdir -p "$STALE"
expect_refused_cmd "a patch that does not apply to the deployed commit refuses" \
  "does not apply to the deployed commit $DEPLOYED_SHA" reconstruct_tree "$WORK/stale.patch" "$STALE" "$DEPLOYED_SHA"
[ "$(cat "$STALE/platforms/buildvm.nix")" = "$(cat "$BASELINE/platforms/buildvm.nix")" ] \
  || fail "the refused patch must leave the copy of the baseline untouched"
echo "ok: git apply --check refuses a stale patch before touching the tree"

# A series that reaches outside the allowlist, and one that reaches the gate itself, both survive
# reconstruction and are refused by the guards -- which is why the guards run on the rebuilt tree.
mkdir -p "$SRC/nixosModules/evil"
printf 'bad\n' > "$SRC/nixosModules/evil/default.nix"
commit_src "adds an out-of-scope tree"
git -C "$SRC" format-patch -1 HEAD --stdout > "$WORK/outscope.patch"
OUTSCOPE=$WORK/outscope
mkdir -p "$OUTSCOPE"
reconstruct_tree "$WORK/outscope.patch" "$OUTSCOPE" "$DEPLOYED_SHA"
expect_refused_cmd "out-of-scope submission refused by check_scope" \
  "outside the deploy-ai allowlist" check_scope "$OUTSCOPE"

printf '# patched by a submission\n' >> "$SRC/pkgs/deploy-ai/deploy-ai.sh"
commit_src "edits the gate's own script"
git -C "$SRC" format-patch -1 HEAD --stdout > "$WORK/gate.patch"
GATE=$WORK/gate
mkdir -p "$GATE"
reconstruct_tree "$WORK/gate.patch" "$GATE" "$DEPLOYED_SHA"
expect_ok_cmd "pkgs/deploy-ai/ is inside the allowlist, so check_scope passes" check_scope "$GATE"
expect_refused_cmd "a submission editing the gate refused by check_deny" \
  "on the deploy-ai denylist" check_deny "$GATE"

# ------------------------------------------------------------------ flag routing

if [ "$(id -u)" -eq 0 ]; then
  echo "skip: routing checks, they exercise the root guard as root"
else
  # --vet alone reaches the submit path, which refuses before reading stdin.  Run in a subshell so
  # the parsed flags do not leak into the rest of the fixture.
  expect_refused_cmd "--vet reaches the submit path" "must run as root" main --vet
  expect_refused_cmd "--submit reaches the submit path" "must run as root" main --submit
  if out=$(trap - EXIT; main --not-a-flag 2>&1); then
    fail "an unknown flag should be refused"
  fi
  printf '%s\n' "$out" | grep -q 'deploy-ai --vet' \
    || fail "an unknown flag should print the usage; output was: $out"
  echo "ok: --vet/--submit route to the submit path, an unknown flag prints usage"
fi

echo "deploy-ai scope guard: all checks passed"
