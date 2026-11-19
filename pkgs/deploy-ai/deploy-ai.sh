#!/usr/bin/env bash
# deploy-ai - the only way anything changes ai's system.  Runs as root, normally through the
# forced-command account deployer, which the build VM's key is authorized for.
#
# Guards, in order: the deployed commit must be an ancestor of --ref, and the tree diff against the
# source of the running system must stay inside nixflakes.deploy-ai.allowlist.  After the switch a
# failed health probe rolls back, backed by a timed reboot guard.
#
# The flake is built inside the build VM (qemu on this host) and its store closure copied back with
# nix-copy-closure.  No repo lives on ai, so --repo names one on every call that fetches.
set -euo pipefail
umask 022

# Every path is overridable so pkgs/deploy-ai/test-scope.sh can exercise the guards as an
# unprivileged user; the defaults are what the NixOS module installs.
STATE=${DEPLOY_AI_STATE:-/var/lib/deploy-ai}
ALLOWLIST=${DEPLOY_AI_ALLOWLIST:-/etc/deploy-ai/allowlist}
MIRROR=$STATE/repo
AI=ai

# Baseline: the source and revision that produced the running system, recorded in /etc by the
# module.  DEPLOY_AI_BASELINE names the source directly, DEPLOY_AI_BASELINE_COMMIT the commit file.
BASELINE_FILE=${DEPLOY_AI_BASELINE_FILE:-/etc/deploy-ai/deployed-source}
BASELINE_COMMIT=${DEPLOY_AI_BASELINE_COMMIT:-/etc/deploy-ai/deployed-commit}
BASELINE=${DEPLOY_AI_BASELINE:-}
if [ -z "$BASELINE" ] && [ -r "$BASELINE_FILE" ]; then
  BASELINE=$(head -n 1 "$BASELINE_FILE")
fi
BASELINE=${BASELINE:-$BASELINE_FILE}

# The guest is ssh as builder on the port qemu forwards, using a key the buildvm module generates.
# Only its location is published in /etc, so nothing here hardcodes a buildvm path.
BUILD_HOST=127.0.0.1
BUILD_PORT=2224
BUILDER=builder
BUILD_KEY_FILE=${DEPLOY_AI_BUILD_KEY_FILE:-/etc/deploy-ai/build-key}
BUILD_KEY=${DEPLOY_AI_BUILD_KEY:-}
if [ -z "$BUILD_KEY" ] && [ -r "$BUILD_KEY_FILE" ]; then
  BUILD_KEY=$(head -n 1 "$BUILD_KEY_FILE")
fi
BUILD_KEY=${BUILD_KEY:-/var/lib/buildvm/secrets/id_ed25519}
GUEST_CANDIDATE=${DEPLOY_AI_GUEST_CANDIDATE:-/home/builder/deploy-candidate}
RECORDED_COMMIT=/home/builder/deployed-commit
BUILD_TIMEOUT=3600

# Submit path: the build VM sends a patch series on stdin and ai rebuilds the tree from its own
# baseline.  Everything the gate enforces is read out of /etc, so a patch cannot redefine it.
SUBMIT_MAX_BYTES_FILE=${DEPLOY_AI_SUBMIT_MAX_BYTES_FILE:-/etc/deploy-ai/submit-max-bytes}
SUBMIT_MAX_BYTES=${DEPLOY_AI_SUBMIT_MAX_BYTES:-}
if [ -z "$SUBMIT_MAX_BYTES" ] && [ -r "$SUBMIT_MAX_BYTES_FILE" ]; then
  SUBMIT_MAX_BYTES=$(head -n 1 "$SUBMIT_MAX_BYTES_FILE")
fi
# Only a host with no file at all falls back here; an uncapped read from the guest is not an option.
SUBMIT_MAX_BYTES=${SUBMIT_MAX_BYTES:-262144}

# Guest-only paths and the denylist have the same shape as $ALLOWLIST: prefix entries end in /,
# bare entries name one exact file.
GUEST_ONLY_FILE=${DEPLOY_AI_GUEST_ONLY_FILE:-/etc/deploy-ai/guest-only-paths}
DENY_FILE=${DEPLOY_AI_DENY_FILE:-/etc/deploy-ai/denylist}
POLICY_FILE=${DEPLOY_AI_POLICY_FILE:-/etc/deploy-ai/policy-digest}
INBOX=${DEPLOY_AI_INBOX:-$STATE/inbox}
GUEST_ATTR=${DEPLOY_AI_GUEST_ATTR:-buildvm}
RECORDED_GUEST_COMMIT=${DEPLOY_AI_RECORDED_GUEST_COMMIT:-$STATE/guest-commit}
# The repository the guest computes its own `deployed..main` range in; the tag moves once a
# submission is live.
GUEST_REPO=${DEPLOY_AI_GUEST_REPO:-/home/builder/nixflakes}

# Guest root's key, for the switch inside the VM.  As with the builder key, /etc publishes only
# where it lives.
GUEST_ROOT_KEY_FILE=${DEPLOY_AI_GUEST_ROOT_KEY_FILE:-/etc/deploy-ai/guest-root-key}
GUEST_ROOT_KEY=${DEPLOY_AI_GUEST_ROOT_KEY:-}
if [ -z "$GUEST_ROOT_KEY" ] && [ -r "$GUEST_ROOT_KEY_FILE" ]; then
  GUEST_ROOT_KEY=$(head -n 1 "$GUEST_ROOT_KEY_FILE")
fi

# nix eval of the reconstructed tree: config evaluation only, but it still copies the tree in.
EVAL_TIMEOUT=600

# Health probe and the reboot guard that backs the rollback.
HEALTH_RETRIES=24
HEALTH_WAIT=5
API=http://127.0.0.1:8642/api/v1/health
UNITS=(hermes-agent hermes-backend hermes-webui)
GUARD_MINUTES=60

REF=
REPO=
DRY_RUN=0
BUILD_LOCAL=0
STATUS_ONLY=0
SUBMIT=0
VET_ONLY=0
TOPLEVEL=
GUEST_TOPLEVEL=

usage() {
  cat <<'USAGE'
deploy-ai: build and switch ai from a commit in a git repository.

  deploy-ai --repo <url> --ref <rev>     build <rev> on the VM and switch ai to it
  deploy-ai --repo <url> --ref <rev> --dry-run
  deploy-ai --repo <url> --list          refs visible in that repository
  deploy-ai --status                     what is deployed now, and why
  deploy-ai --submit                     vet a patch series on stdin and provision it immediately
  deploy-ai --vet                        the same checks, nothing applied; prints the verdict
  deploy-ai --submit --dry-run           vet and report, apply nothing

<url> is any git URL root can read: the git host, or a repository on the VM
(ssh://builder@127.0.0.1:2224/home/builder/nixflakes).  --repo is required for anything
that fetches.

  --local     build on ai instead of the VM, for an operator who wants that

--submit/--vet read a series from stdin, e.g.

  git format-patch --stdout deployed..main | ssh deployer@10.0.2.2 'deploy-ai --submit'

The patch is applied to the source of the running system, never to a tree the guest supplies.
A submission that changes only build-VM paths switches the build VM; anything else goes through
the switch path above, with the same rollback and health guards.
USAGE
}

die() {
  echo "deploy-ai: refusing: $*" >&2
  exit 1
}

# ------------------------------------------------------------------ plumbing

need() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (the deployer account reaches it with sudo)"
  [ -r "$ALLOWLIST" ] || die "$ALLOWLIST is missing; enable nixflakes.deploy-ai on ai first"
}

# git over ssh, using the guest key.  For a repo on the VM it is the only identity accepted, so
# IdentitiesOnly; for a git host it is offered alongside whatever root has.
ssh_command() {
  case $REPO in
    *127.0.0.1:* | *localhost:*)
      printf 'ssh -i %s -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' "$BUILD_KEY"
      ;;
    *)
      if [ -r "$BUILD_KEY" ]; then
        printf 'ssh -i %s -o StrictHostKeyChecking=accept-new' "$BUILD_KEY"
      else
        printf 'ssh -o StrictHostKeyChecking=accept-new'
      fi
      ;;
  esac
}

mirror() {
  mkdir -p "$STATE"
  if [ ! -d "$MIRROR" ]; then
    git init --bare --quiet "$MIRROR" || die "cannot create $MIRROR"
    git --git-dir="$MIRROR" remote add origin "$REPO"
  fi
  git --git-dir="$MIRROR" remote set-url origin "$REPO"
  GIT_SSH_COMMAND="$(ssh_command)" \
    git --git-dir="$MIRROR" fetch --quiet --prune origin '+refs/heads/*:refs/heads/*' \
    || die "cannot fetch $REPO; check the URL and that root's key (or the VM key) is authorized"
}

acquire_lock() {
  mkdir "$STATE" 2>/dev/null || true
  mkdir "$STATE/lock" 2>/dev/null || die "another deploy-ai is running ($STATE/lock exists); wait for it"
}

# ------------------------------------------------------------------ scope and history guards

parse_allowlist() {
  awk 'NF && $1 !~ /^#/ { print $1 }' "$ALLOWLIST"
}

# A prefix entry ends in / and matches everything under it; a bare entry names one exact file.
in_scope() {
  local path=$1 entry
  while read -r entry; do
    [ -n "$entry" ] || continue
    case $entry in
      */)
        case $path in
          "$entry"*) return 0 ;;
        esac
        ;;
      *)
        [ "$path" = "$entry" ] && return 0
        ;;
    esac
  done <<< "$(parse_allowlist)"
  return 1
}

# Makes a refusal actionable by naming the entries that already cover the refused path's area.
nearest_dir() {
  local path=$1 dir entry hits=
  dir=$(dirname "$path")
  while read -r entry; do
    [ -n "$entry" ] || continue
    case ${entry%/} in
      "$dir" | "$dir"/*) hits="$hits $entry" ;;
    esac
    case $path in
      "${entry%/}"/*) hits="$hits $entry" ;;
    esac
  done <<< "$(parse_allowlist)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
  elif [ "$dir" = "." ]; then
    printf 'no top-level files are allowed\n'
  else
    printf 'nothing under %s is allowed\n' "$dir"
  fi
}

refuse_scope() {
  local path=$1
  echo "deploy-ai: refusing: '$path' is outside the deploy-ai allowlist." >&2
  echo "  allowlist:    $(tr '\n' ' ' < "$ALLOWLIST")" >&2
  echo "  nearest dir:  $(nearest_dir "$path")" >&2
  echo "  move the change there, or ask the operator to widen nixflakes.deploy-ai.allowlist." >&2
  exit 1
}

baseline_commit() {
  local base
  if [ -f "$STATE/commit" ]; then
    base=$(head -n 1 "$STATE/commit")
  elif [ -r "$BASELINE_COMMIT" ] && [ -s "$BASELINE_COMMIT" ]; then
    base=$(head -n 1 "$BASELINE_COMMIT")
  else
    die "no baseline commit recorded; ask the operator to deploy $AI once out-of-band"
  fi
  # A switch from a dirty tree records `<rev>-dirty`, which is no commit; compare against the
  # commit the snapshot came from, since the uncommitted part is caught by the content diff.
  case $base in
    *-dirty)
      base=${base%-dirty}
      echo "deploy-ai: note: the recorded baseline was a dirty tree; checking against $base" >&2
      ;;
  esac
  printf '%s\n' "$base"
}

# Every path that differs between the baseline source and the candidate tree.  Content comparison,
# not names: a rewritten history cannot hide a changed file.
changed_paths() {
  local candidate=$1 out
  # diff exits 1 when files differ; under pipefail that would abort every deploy that changes
  # something.
  out=$(diff -rq \
    --exclude=.git --exclude=.direnv --exclude=.ralph --exclude=result \
    --exclude=state.json --exclude=secrets --exclude=nix-support \
    "$BASELINE" "$candidate" 2>/dev/null || true)
  printf '%s\n' "$out" | awk -v a="$BASELINE" -v b="$candidate" '
      /^Files / {
        p = $0; sub(/^Files /, "", p); sub(/ and .*$/, "", p); sub("^" a "/", "", p);
        print p; next
      }
      /^Only in / {
        # diff -rq names a new or removed directory, not the files in it; that is the right
        # granularity to refuse, and the path stays repo-relative.
        p = $0; sub(/^Only in /, "", p);
        dir = p; sub(/: .*$/, "", dir);
        name = p; sub(/^.*: /, "", name);
        if (dir == a || dir == b) { print name; next }
        sub("^" a "/", "", dir); sub("^" b "/", "", dir);
        print dir "/" name; next
      }
    ' | sort -u
}

check_history() {
  local base=$1
  git --git-dir="$MIRROR" merge-base --is-ancestor "$base" "$SHA" \
    || die "$SHA does not have the deployed commit $base in its history; rebase onto it, or the operator deploys out-of-band"
}

check_scope() {
  local candidate=$1 path
  [ -d "$BASELINE" ] || die "$BASELINE is missing; the running system was built without nixflakes.deploy-ai.deployedSource"
  while read -r path; do
    [ -n "$path" ] || continue
    in_scope "$path" || refuse_scope "$path"
  done <<< "$(changed_paths "$candidate")"
}

# ------------------------------------------------------------------ submit guards

# Same file shape as $ALLOWLIST, for the two lists only the submit path reads.
parse_path_list() {
  awk 'NF && $1 !~ /^#/ { print $1 }' "$1"
}

# in_scope() against an arbitrary list file: a prefix entry ends in /, a bare entry is one file.
matches_path() {
  local path=$1 list=$2 entry
  while read -r entry; do
    [ -n "$entry" ] || continue
    case $entry in
      */)
        case $path in
          "$entry"*) return 0 ;;
        esac
        ;;
      *)
        [ "$path" = "$entry" ] && return 0
        ;;
    esac
  done <<< "$(parse_path_list "$list")"
  return 1
}

refuse_deny() {
  local path=$1
  echo "deploy-ai: refusing: '$path' is on the deploy-ai denylist." >&2
  echo "  denylist:     $(tr '\n' ' ' < "$DENY_FILE")" >&2
  echo "  it touches the deployment machinery itself, so the operator must apply that out-of-band." >&2
  echo "  $DENY_FILE names every entry." >&2
  exit 1
}

# The gate's own machinery is off-limits to a patch: the thing doing the vetting cannot vet a
# change to itself.
check_deny() {
  local candidate=$1 path
  [ -r "$DENY_FILE" ] || die "$DENY_FILE is missing; enable nixflakes.deploy-ai on ai first"
  while read -r path; do
    [ -n "$path" ] || continue
    matches_path "$path" "$DENY_FILE" && refuse_deny "$path"
  done <<< "$(changed_paths "$candidate")"
  # Without this the loop's status is the last failed match, so an accepted tree reads as a
  # refusal and `set -e` aborts the submit with no message.
  return 0
}

# A submission only stays inside the VM when every changed path is one the VM owns; anything else
# can reach ai and has to go through ai's switch path.
classify_changes() {
  local candidate=$1 path
  [ -r "$GUEST_ONLY_FILE" ] || die "$GUEST_ONLY_FILE is missing; enable nixflakes.deploy-ai on ai first"
  while read -r path; do
    [ -n "$path" ] || continue
    matches_path "$path" "$GUEST_ONLY_FILE" || { printf 'ai\n'; return 0; }
  done <<< "$(changed_paths "$candidate")"
  printf 'guest\n'
}

# The policy digest is evaluated out of the patched tree, so a submission cannot quietly widen
# what the gate enforces.  nix's own error stays on stderr.
policy_digest() {
  local tree=$1
  timeout "$EVAL_TIMEOUT" nix eval --raw --accept-flake-config \
    "$tree#nixosConfigurations.$AI.config.nixflakes.deploy-ai.policyDigest"
}

# The digest evaluated from the patched tree must be the one ai already enforces.
check_policy() {
  local actual=$1 want
  want=$(head -n 1 "$POLICY_FILE" 2>/dev/null) || die "cannot read $POLICY_FILE"
  [ -n "$actual" ] || die "cannot evaluate nixflakes.deploy-ai.policyDigest of the submitted tree; nothing was applied"
  [ "$actual" = "$want" ] \
    || die "the patch changes the deployment policy (allowlist, keys, users, sudoers); the operator must apply that out-of-band"
}

# ------------------------------------------------------------------ build

# ssh into the guest.  Guest-side paths are single-quoted inside the command and are only ever
# values set above, never guest-supplied text, so the guest cannot reach outside /home/builder.
vm_ssh() {
  ssh -i "$BUILD_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 -p "$BUILD_PORT" "$BUILDER@$BUILD_HOST" "$@"
}

# The same host and port as vm_ssh(), as root, for the one command that needs privileges inside
# the guest.  StrictHostKeyChecking=accept-new and no known_hosts: qemu's port forwards a single
# guest that is re-created often.
guest_root_ssh() {
  ssh -i "$GUEST_ROOT_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
      -p "$BUILD_PORT" "root@$BUILD_HOST" "$@"
}

# Hand the candidate tree over as plain files; the VM needs no repo access to build, only its own
# key for git-hosted flake inputs.
send_candidate() {
  git --git-dir="$MIRROR" archive --format=tar "$SHA" \
    | vm_ssh "rm -rf '$GUEST_CANDIDATE' && mkdir -p '$GUEST_CANDIDATE' && tar -x -C '$GUEST_CANDIDATE'" \
    || die "cannot unpack $SHA into $GUEST_CANDIDATE on the VM"
}

build_on_vm() {
  echo "deploy-ai: building nixosConfigurations.$AI on the VM…"
  local log=$STATE/log/build.log
  mkdir -p "$STATE/log"
  timeout "$BUILD_TIMEOUT" vm_ssh \
    "cd '$GUEST_CANDIDATE' && nix build --no-link --print-out-paths --accept-flake-config '$GUEST_CANDIDATE#nixosConfigurations.$AI.config.system.build.toplevel'" \
    > "$log" 2>&1 || { tail -n 40 "$log" >&2; die "build failed on the VM; log: $log"; }
  TOPLEVEL=$(tail -n 1 "$log")
  case $TOPLEVEL in
    /nix/store/*) ;;
    *) die "the VM build printed no output path" ;;
  esac
  echo "deploy-ai: copying the closure back to ai…"
  NIX_SSHOPTS="-i $BUILD_KEY -p $BUILD_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
    nix-copy-closure --from "$BUILDER@$BUILD_HOST" "$TOPLEVEL" \
    || die "nix-copy-closure failed; the VM is reachable but its store could not be read"
}

build_local() {
  echo "deploy-ai: building nixosConfigurations.$AI on ai…"
  local log=$STATE/log/build.log
  mkdir -p "$STATE/log"
  timeout "$BUILD_TIMEOUT" nix build --no-link --print-out-paths --accept-flake-config \
    "git+file://$MIRROR?ref=$(git --git-dir="$MIRROR" rev-parse "$SHA")#nixosConfigurations.$AI.config.system.build.toplevel" \
    > "$log" 2>&1 || { tail -n 40 "$log" >&2; die "build failed; log: $log"; }
  TOPLEVEL=$(tail -n 1 "$log")
}

# ------------------------------------------------------------------ switch

current_system() {
  readlink -f /run/current-system
}

check_health() {
  local unit
  for unit in "${UNITS[@]}"; do
    systemctl is-active --quiet "$unit" || return 1
  done
  curl -fsS --max-time 5 "$API" > /dev/null || return 1
  vm_ssh 'echo ok' > /dev/null || return 1
  return 0
}

wait_health() {
  local i
  for ((i = 0; i < HEALTH_RETRIES; i++)); do
    check_health && return 0
    sleep "$HEALTH_WAIT"
  done
  return 1
}

# Remember where to come back to, before touching the switch.
record_rollback() {
  local previous=$1
  printf '%s\n' "$previous" > "$STATE/rollback-previous"
  : > "$STATE/rollback-pending"
}

clear_rollback() {
  rm -f "$STATE/rollback-pending"
}

rollback() {
  local previous
  previous=$(cat "$STATE/rollback-previous" 2>/dev/null || echo '')
  [ -n "$previous" ] && [ -x "$previous/bin/switch-to-configuration" ] \
    || { echo "deploy-ai: no rollback target recorded; leaving the new system in place" >&2; return 1; }
  echo "deploy-ai: rolling back to $previous" >&2
  "$previous/bin/switch-to-configuration" switch || true
}

do_switch() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "deploy-ai: dry run; would switch ai to $TOPLEVEL"
    return 0
  fi
  "$TOPLEVEL/bin/switch-to-configuration" switch
}

# Tell the VM which commit is live, so the agent's own tree can be compared against reality.
record_in_guest() {
  vm_ssh "printf '%s\n' '$SHA' > '$RECORDED_COMMIT'" 2>/dev/null \
    || echo "deploy-ai: warning: could not write $RECORDED_COMMIT in the VM" >&2
}

# The guard is a timed reboot: if the new system hangs, boot finds the recorded rollback.
arm_guard() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  if systemctl reboot --when "+${GUARD_MINUTES}m" 2>/dev/null; then
    echo "deploy-ai: guard armed: reboot in ${GUARD_MINUTES}m unless cancelled by a healthy switch"
  else
    echo "deploy-ai: warning: timed reboot unavailable; no automatic reboot on a hang" >&2
  fi
}

cancel_guard() {
  systemctl cancel --when 2>/dev/null || true
}

# ------------------------------------------------------------------ commands

do_status() {
  echo "deployed commit:    $(cat "$STATE/commit" 2>/dev/null || head -n 1 "$BASELINE_COMMIT" 2>/dev/null || echo none)"
  echo "deployed toplevel:  $(cat "$STATE/toplevel" 2>/dev/null || readlink -f /run/current-system)"
  echo "baseline source:    ${BASELINE} $(if [ -e "$BASELINE" ]; then echo '(present)'; else echo '(missing)'; fi)"
  echo "pending rollback:   $([ -e "$STATE/rollback-pending" ] && cat "$STATE/rollback-previous" 2>/dev/null || echo none)"
  # ai's own record first; the VM's copy only tells us what it was last told, and only if it is up.
  echo "guest commit:       $(head -n 1 "$RECORDED_GUEST_COMMIT" 2>/dev/null \
    || vm_ssh "head -n 1 '$RECORDED_COMMIT'" 2>/dev/null || echo none)"
  echo "policy:             $(head -n 1 "$POLICY_FILE" 2>/dev/null || echo none) (immutable by patch)"
  echo "allowlist:"
  sed 's/^/  /' "$ALLOWLIST"
  systemctl list-timers --all 2>/dev/null | grep -i 'reboot' || true
}

do_deploy() {
  need
  [ -n "$REPO" ] || die "--repo is required; name the repository to read"
  mirror
  SHA=$(git --git-dir="$MIRROR" rev-parse --verify "$REF^{commit}" 2>/dev/null) \
    || die "$REF does not exist in $REPO; run 'deploy-ai --repo \"$REPO\" --list'"

  BASE=$(baseline_commit)
  check_history "$BASE"

  acquire_lock
  WORK=$(mktemp -d /tmp/deploy-ai-tree.XXXXXXXX)
  # One trap for both resources: a second `trap ... EXIT` would replace the first and leave the
  # lock directory behind.
  trap 'rm -rf "$WORK"; rmdir "$STATE/lock" 2>/dev/null || true' EXIT INT TERM
  git --git-dir="$MIRROR" archive --format=tar "$SHA" | tar -x -C "$WORK"
  check_scope "$WORK"

  if [ "$BUILD_LOCAL" -eq 1 ]; then build_local; else send_candidate; build_on_vm; fi

  CURRENT=$(current_system)
  record_rollback "$CURRENT"

  # The current system must be healthy before a switch, or the switch hides an existing break.
  if ! check_health; then
    clear_rollback
    die "the CURRENT system is already unhealthy; switching would hide that.  Fix it out-of-band or reboot $AI"
  fi

  # Armed only now: a build that fails after an hour must not leave a reboot pending.
  arm_guard
  do_switch

  if ! wait_health; then
    echo "deploy-ai: the new system never became healthy; switching back" >&2
    rollback
    clear_rollback
    cancel_guard
    die "deploy of $SHA failed and was rolled back; log: $STATE/log/build.log"
  fi

  clear_rollback
  cancel_guard
  printf '%s\n' "$TOPLEVEL" > "$STATE/toplevel"
  printf '%s\n' "$SHA" > "$STATE/commit"
  printf '%s\t%s\t%s\n' "$(date -Is)" "$SHA" "$TOPLEVEL" >> "$STATE/refs.log"
  record_in_guest
  echo "deploy-ai: ai is now running $SHA ($TOPLEVEL)"
}

do_list() {
  need
  [ -n "$REPO" ] || die "--repo is required"
  mirror
  git --git-dir="$MIRROR" for-each-ref --format='%(refname) %(objectname:short) %(committerdate:relative)' refs/heads
  echo "deployed: $(cat "$STATE/commit" 2>/dev/null || echo none)"
}

# ------------------------------------------------------------------ submit

# The series arrives on stdin: the deployer account's forced command passes it through.  Reading
# one byte past the cap refuses an oversized submission without buffering all of it, and the
# contents are never echoed.
save_incoming_patch() {
  local dest=$INBOX/$(date -u +%Y%m%dT%H%M%SZ)-$$.patch size
  case $SUBMIT_MAX_BYTES in
    '' | *[!0-9]*) die "$SUBMIT_MAX_BYTES_FILE does not hold an integer: '$SUBMIT_MAX_BYTES'" ;;
  esac
  mkdir -p "$INBOX" 2>/dev/null || die "cannot create $INBOX"
  chmod 700 "$INBOX" 2>/dev/null || true
  # The submission is kept as the record of what arrived, readable only by root.
  : > "$dest" && chmod 600 "$dest" || die "cannot write $dest"
  head -c "$((SUBMIT_MAX_BYTES + 1))" > "$dest" || die "cannot read the patch from stdin"
  size=$(wc -c < "$dest")
  [ "$size" -le "$SUBMIT_MAX_BYTES" ] \
    || die "patch too large: $size bytes, over the $SUBMIT_MAX_BYTES limit in $SUBMIT_MAX_BYTES_FILE"
  [ "$size" -gt 0 ] || die "empty patch on stdin; nothing to submit"
  printf '%s\n' "$dest"
}

# Rebuilds the candidate as ai's baseline plus the patch, and sets SHA.  The guest sends a diff,
# never a tree, so no guest-supplied path, file list, or commit object is trusted.  `git apply`
# rather than `git am`: the guest's commit metadata is not trusted either, and one host-authored
# commit is what the records name.
reconstruct_tree() {
  local patch=$1 dest=$2 base=$3
  [ -d "$BASELINE" ] || die "$BASELINE is missing; the running system was built without nixflakes.deploy-ai.deployedSource"
  tar -C "$BASELINE" -cf - . | tar -x -C "$dest" || die "cannot copy $BASELINE into $dest"
  # A baseline from the store is read-only, and `git apply` has to rewrite the files it touches.
  chmod -R u+w "$dest"
  git -C "$dest" init --quiet
  git -C "$dest" apply --check -p1 "$patch" \
    || die "the patch does not apply to the deployed commit $base; rebase it onto $base and submit again"
  git -C "$dest" apply -p1 "$patch" \
    || die "the patch does not apply to the deployed commit $base"
  git -C "$dest" add -A
  git -C "$dest" -c user.name=deploy-ai -c user.email=deploy-ai@localhost \
    commit --quiet -m "deploy-ai submit onto $base" \
    || die "cannot commit the reconstructed tree in $dest"
  SHA=$(git -C "$dest" rev-parse HEAD)
}

# The reconstructed tree handed over as plain files, so the VM needs no repo access to build it.
# `.git` stays on ai: nothing about the host-side commit travels.
send_tree() {
  local tree=$1
  tar -C "$tree" --exclude=.git -cf - . \
    | vm_ssh "rm -rf '$GUEST_CANDIDATE' && mkdir -p '$GUEST_CANDIDATE' && tar -x -C '$GUEST_CANDIDATE'" \
    || die "cannot unpack the submitted tree into $GUEST_CANDIDATE on the VM"
}

# The guest's own system, built inside the VM.  What it printed is checked below before anything
# is activated.
build_guest_system() {
  local log=$STATE/log/guest-build.log
  mkdir -p "$STATE/log"
  echo "deploy-ai: building nixosConfigurations.$GUEST_ATTR on the VM…"
  timeout "$BUILD_TIMEOUT" vm_ssh \
    "cd '$GUEST_CANDIDATE' && nix build --no-link --print-out-paths --accept-flake-config '$GUEST_CANDIDATE#nixosConfigurations.$GUEST_ATTR.config.system.build.toplevel'" \
    > "$log" 2>&1 || { tail -n 40 "$log" >&2; die "guest build failed on the VM; log: $log"; }
  GUEST_TOPLEVEL=$(tail -n 1 "$log")
  case $GUEST_TOPLEVEL in
    /nix/store/*) ;;
    *) die "the VM build printed no output path" ;;
  esac
}

# ai evaluates the same tree the VM just built.  A path ai does not recognize is a VM that built
# something else, and activating it would run a system nobody vetted.
verify_output() {
  local attr=$1 printed=$2 tree=$3 expected
  expected=$(timeout "$EVAL_TIMEOUT" nix eval --raw --accept-flake-config \
    "$tree#nixosConfigurations.$attr.config.system.build.toplevel.outPath" 2>/dev/null) \
    || die "cannot evaluate the toplevel path of nixosConfigurations.$attr; nothing was switched"
  [ "$printed" = "$expected" ] \
    || die "the VM's build output does not match what ai computed: $printed != $expected; nothing was switched"
}

# A guest-only submission switches the VM and leaves ai running what it runs now.
apply_guest() {
  local tree=$1 sha=$2
  send_tree "$tree"
  build_guest_system
  verify_output "$GUEST_ATTR" "$GUEST_TOPLEVEL" "$tree"

  [ -n "$GUEST_ROOT_KEY" ] || die "no key for guest root; set $GUEST_ROOT_KEY_FILE or DEPLOY_AI_GUEST_ROOT_KEY"
  [ -r "$GUEST_ROOT_KEY" ] || die "$GUEST_ROOT_KEY is not readable; the guest switch needs it"
  echo "deploy-ai: switching the VM to $GUEST_TOPLEVEL…"
  guest_root_ssh "nixos-rebuild switch --flake '$GUEST_CANDIDATE#$GUEST_ATTR' --accept-flake-config" \
    || die "the guest switch failed; ai is unchanged"

  # Records only: a switch that landed but could not be recorded is still live.
  printf '%s\n' "$sha" > "$RECORDED_GUEST_COMMIT" 2>/dev/null \
    || echo "deploy-ai: warning: could not write $RECORDED_GUEST_COMMIT" >&2
  vm_ssh "printf '%s\n' '$sha' > '$RECORDED_COMMIT'" 2>/dev/null \
    || echo "deploy-ai: warning: could not write $RECORDED_COMMIT in the VM" >&2
  vm_ssh "git -C '$GUEST_REPO' tag -f deployed '$sha'" 2>/dev/null \
    || echo "deploy-ai: warning: could not move the deployed tag in $GUEST_REPO in the VM" >&2
  echo "deploy-ai: the VM is now running $sha ($GUEST_TOPLEVEL); ai is unchanged"
}

# Anything else takes the same road as --repo/--ref, including the rollback and health guards.
apply_on_ai() {
  local tree=$1 sha=$2
  send_tree "$tree"
  build_on_vm
  verify_output "$AI" "$TOPLEVEL" "$tree"

  CURRENT=$(current_system)
  record_rollback "$CURRENT"

  # The current system must be healthy before a switch, or the switch hides an existing break.
  if ! check_health; then
    clear_rollback
    die "the CURRENT system is already unhealthy; switching would hide that.  Fix it out-of-band or reboot $AI"
  fi

  # Armed only now: a build that fails after an hour must not leave a reboot pending.
  arm_guard
  do_switch

  if ! wait_health; then
    echo "deploy-ai: the new system never became healthy; switching back" >&2
    rollback
    clear_rollback
    cancel_guard
    die "deploy of $sha failed and was rolled back; log: $STATE/log/build.log"
  fi

  clear_rollback
  cancel_guard
  printf '%s\n' "$TOPLEVEL" > "$STATE/toplevel"
  printf '%s\n' "$sha" > "$STATE/commit"
  printf '%s\t%s\t%s\n' "$(date -Is)" "$sha" "$TOPLEVEL" >> "$STATE/refs.log"
  record_in_guest
  printf '%s\n' "$sha" > "$RECORDED_GUEST_COMMIT"
  echo "deploy-ai: ai is now running $sha ($TOPLEVEL)"
}

do_submit() {
  need
  [ -r "$POLICY_FILE" ] || die "$POLICY_FILE is missing; enable nixflakes.deploy-ai on ai first"
  [ "$BUILD_LOCAL" -eq 0 ] || die "--submit builds on the VM like every other deploy; --local belongs to --repo/--ref"

  acquire_lock
  WORK=$(mktemp -d /tmp/deploy-ai-submit.XXXXXXXX)
  # One trap for both resources: a second `trap ... EXIT` would replace the first and leave the
  # lock directory behind.
  trap 'rm -rf "$WORK"; rmdir "$STATE/lock" 2>/dev/null || true' EXIT INT TERM

  PATCH_FILE=$(save_incoming_patch)
  BASE=$(baseline_commit)
  reconstruct_tree "$PATCH_FILE" "$WORK" "$BASE"

  check_scope "$WORK"
  check_deny "$WORK"
  POLICY_ACTUAL=$(policy_digest "$WORK") || die "cannot evaluate $AI's policy digest of the submitted tree; nothing was applied"
  check_policy "$POLICY_ACTUAL"
  CLASS=$(classify_changes "$WORK")

  echo "deploy-ai: submitted tree $SHA, onto $BASE: class $CLASS"
  changed_paths "$WORK" | sed 's/^/  changed:  /'
  echo "  policy:   $POLICY_ACTUAL, unchanged from $POLICY_FILE"

  if [ "$VET_ONLY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    echo "deploy-ai: nothing applied ($([ "$VET_ONLY" -eq 1 ] && echo --vet || echo --dry-run))"
    return 0
  fi
  case $CLASS in
    guest) apply_guest "$WORK" "$SHA" ;;
    *) apply_on_ai "$WORK" "$SHA" ;;
  esac
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) REPO=${2:-}; shift 2 ;;
      --repo=*) REPO=${1#*=}; shift ;;
      --ref) REF=${2:-}; shift 2 ;;
      --ref=*) REF=${1#*=}; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --local) BUILD_LOCAL=1; shift ;;
      --status) STATUS_ONLY=1; shift ;;
      --list) LIST=1; shift ;;
      --submit) SUBMIT=1; shift ;;
      --vet) VET_ONLY=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  if [ "$STATUS_ONLY" -eq 1 ]; then
    need
    do_status
    return 0
  fi
  if [ "${LIST:-0}" -eq 1 ]; then
    do_list
    return 0
  fi
  if [ "$SUBMIT" -eq 1 ] || [ "$VET_ONLY" -eq 1 ]; then
    do_submit
    return 0
  fi
  [ -n "$REF" ] || { usage; exit 1; }
  do_deploy
}

# Sourcing the file for tests must not run it.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
