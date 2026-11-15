#!/usr/bin/env bash
# One-time btrfs setup for Hermes' Docker sandbox store on `ai`.
#
# Creates the subvolume that platforms/ai.nix mounts at /var/lib/docker, enables subvolume
# quota support on the filesystem, and caps that subvolume at 500 GiB.  Docker cannot enforce a
# disk quota on btrfs (`--storage-opt size=` is XFS+pquota only — see
# daemon/graphdriver/overlay2/overlay.go), so the qgroup limit is the cap: writes past 500 GiB
# inside the subvolume fail with EDQUOT instead of filling the 256 GiB ext4 root.
#
# Run this on `ai` before `sudo nixos-rebuild switch --flake .#ai`; the mount unit fails at boot
# if the subvolume does not exist yet.  Safe to re-run: every step is idempotent.
#
# Qgroup limits live in the filesystem, so they survive reboot; platforms/ai.nix also re-applies
# them from btrfs-docker-quota.service.

set -euo pipefail

POOL_UUID="9e27c0a6-7a7d-41fe-8e83-0ed124cea728"   # /dev/sda1, mkfs.btrfs -L storage_pool
POOL_DEVICE="/dev/disk/by-uuid/${POOL_UUID}"
FS_LABEL="hermes-container"                        # renamed from storage_pool; ai.nix mounts by UUID
MOUNT_POINT="/mnt/hermes-container"                # scratch mount of the fs tree root
SUBVOLUME="docker"                                 # becomes /var/lib/docker
LIMIT="500g"                                       # must match terminal.container_disk = 512000 MB

run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v btrfs >/dev/null 2>&1; then
  echo "error: btrfs-progs not on PATH — run \`nix shell nixpkgs#btrfs-progs\` first (or install it via" >&2
  echo "       platforms/ai.nix, which pulls it in as a filesystem package)." >&2
  exit 1
fi

if [ ! -e "$POOL_DEVICE" ]; then
  echo "error: $POOL_DEVICE not found — is $POOL_UUID still the UUID of the container store?" >&2
  echo "       check with: lsblk -o NAME,SIZE,FSTYPE,UUID,LABEL /dev/sda1" >&2
  exit 1
fi

FS_TYPE="$(run blkid -o value -s TYPE "$POOL_DEVICE" || true)"
if [ "$FS_TYPE" != "btrfs" ]; then
  echo "error: $POOL_DEVICE is '$FS_TYPE', expected btrfs" >&2
  exit 1
fi

# Name the filesystem after what lives on it.  platforms/ai.nix addresses it by UUID, so the
# rename cannot break the mount unit.
CURRENT_LABEL="$(run blkid -o value -s LABEL "$POOL_DEVICE" || true)"
if [ "$CURRENT_LABEL" != "$FS_LABEL" ]; then
  run btrfs filesystem label "$POOL_DEVICE" "$FS_LABEL"
  echo "label: ${CURRENT_LABEL:-none} -> $FS_LABEL"
fi

run mkdir -p "$MOUNT_POINT"

# Already mounted?  Reuse it rather than stacking a second mount on the same directory.
if mountpoint -q "$MOUNT_POINT"; then
  echo "note: $MOUNT_POINT is already mounted; reusing it"
else
  # subvolid=5 is the fs tree root, i.e. the parent of every subvolume.
  run mount -o subvolid=5 "$POOL_DEVICE" "$MOUNT_POINT"
fi

SUBVOL_PATH="${MOUNT_POINT}/${SUBVOLUME}"

if [ -d "$SUBVOL_PATH" ]; then
  echo "note: subvolume ${SUBVOL_PATH} already exists"
else
  run btrfs subvolume create "$SUBVOL_PATH"
fi

# `quota enable` errors out once the quota tree already exists, so the failure is informational.
run btrfs quota enable "$MOUNT_POINT" 2>/dev/null || echo "note: quota tracking already enabled"

run btrfs qgroup limit -e "$LIMIT" "$SUBVOL_PATH"

echo
echo "--- result -------------------------------------------------------------"
run btrfs subvolume list "$MOUNT_POINT" || true
# The configured limit is stored on the qgroup itself, so `qgroup show` reports it alongside usage.
run btrfs qgroup show -reF "$MOUNT_POINT" || true
run btrfs filesystem show "$MOUNT_POINT" || true
echo
echo "Done.  $FS_LABEL /${SUBVOLUME} is capped at ${LIMIT} (exclusive) and will mount at /var/lib/docker."
echo "Next: sudo nixos-rebuild switch --flake .#ai   (run on ai)"
echo "Then verify: findmnt /var/lib/docker && docker info --format '{{.Driver}} {{.DriverStatus}}'"
