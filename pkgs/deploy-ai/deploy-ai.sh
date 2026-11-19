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
TOPLEVEL=

usage() {
  cat <<'USAGE'
deploy-ai: build and switch ai from a commit in a git repository.

  deploy-ai --repo <url> --ref <rev>     build <rev> on the VM and switch ai to it
  deploy-ai --repo <url> --ref <rev> --dry-run
  deploy-ai --repo <url> --list          refs visible in that repository
  deploy-ai --status                     what is deployed now, and why

<url> is any git URL root can read: the git host, or a repository on the VM
(ssh://builder@127.0.0.1:2224/home/builder/nixflakes).  --repo is required for anything
that fetches.

  --local     build on ai instead of the VM, for an operator who wants that
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

# ------------------------------------------------------------------ build

# ssh into the guest.  Guest-side paths are single-quoted inside the command and are only ever
# values set above, never guest-supplied text, so the guest cannot reach outside /home/builder.
vm_ssh() {
  ssh -i "$BUILD_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 -p "$BUILD_PORT" "$BUILDER@$BUILD_HOST" "$@"
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
  [ -n "$REF" ] || { usage; exit 1; }
  do_deploy
}

# Sourcing the file for tests must not run it.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
