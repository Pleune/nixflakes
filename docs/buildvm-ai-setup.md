# Build VM + deploy gate on `ai`: setup runbook

One-time, manual, run as root on `ai` from a checkout of this flake. There are no setup scripts;
none of it is run by the flake. Design and limits: `docs/hermes-agent-flake-deploy.md`.

The agent cannot run any of it — `platforms/ai.nix` `settings.approvals.deny` blocks
`mkfs*`/`wipefs*`/`sgdisk*`/`dd *`/`reboot*` even under yolo (`hermes-agent/tools/approval_floors.py`),
and the deploy gate never touches disks.

⚠️ §3 destroys everything on the 1.82 TiB disk (partition UUID
`9e27c0a6-7a7d-41fe-8e83-0ed124cea728`, today btrfs `hermes-container` mounted at `/var/lib/docker`).
There is no host-side copy of it.

## 1. Inspect the disk

```bash
nix shell nixpkgs#util-linux nixpkgs#gdisk nixpkgs#btrfs-progs   # findfs, sgdisk, mkfs.btrfs
sudo findfs UUID=9e27c0a6-7a7d-41fe-8e83-0ed124cea728
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS /dev/sda
sudo docker system df          # what lives in there
```

Before anything destructive: `hostname` must be `ai`, and `blockdev --getsize64 /dev/sda` must be
~1.82 TB — under ~1.5 TB means the wrong device. To keep a way back, stop Docker and leave the
filesystem in place (§10 is the rollback).

## 2. Deploy keys on the git server (`git.pleunetowne.com:2223`)

One keypair (created in §4) does three jobs:

| Who uses it | What it needs |
| --- | --- |
| `ai` → guest: `ssh -p 2224 builder@127.0.0.1`, Hermes `terminal.ssh_key` | guest authorizes the public half; the install unit does this |
| guest → git host: `nixflakes.git` and the private `secrets` repo | **read deploy key for both** |
| `ai` root: the gate's mirror fetch (`nixflakes.deploy-ai.buildKey`) and `deployer@ai` | host authorizes the public half (`publicKey`), already wired |

The guest needs the `secrets` input at **eval** time (`config/nixos/network/networkmanager` reads
`age.secrets."PT-Git.crt".file`), so `secrets.git` must authorize it too or every guest build fails
before starting. If you made a separate read-only git account for the agent, authorize the key for
that account instead.

## 3. Partition the disk

Set the target explicitly — once the old pool UUID is gone there is nothing to derive it from:

```bash
DISK=/dev/sda
sudo lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT "$DISK"
sudo findmnt -rn -S "$DISK"                  # must print nothing
sudo systemctl stop docker docker.socket     # Docker writes here today

while read -r dev; do [ -b "$dev" ] && sudo wipefs -a "$dev"; done < <(lsblk -nrpo NAME "$DISK")
sudo wipefs -a "$DISK"                       # protective MBR + GPT headers

sudo sgdisk --zap-all "$DISK"
sudo sgdisk --new=1:0:0 --change-name=1:buildvm --typecode=1:linux "$DISK"
sudo sgdisk -p "$DISK"
ls -l /dev/disk/by-partlabel/buildvm
```

`--new=1:0:0` uses the default 1 MiB-aligned first sector and the last *usable* sector, leaving the
trailing 32 sectors for the backup GPT. This partition is what
`nixflakes.virtualisation.buildvm.disk` hands raw to qemu; the guest owns its contents
(`make-disk-image.nix` writes a bare ext4 filesystem at offset 0, which `buildvm-install.service`
grows to fill the partition), so the host mounts nothing here.

## 4. Keypair and guest provisioning

The private half stays on `ai`, outside the repo; the public half goes into
`lib/buildvm/default.nix`. Group `hermes` rather than root-only `0600`, because the gateway and
dashboard units read it as the Hermes user.

```bash
sudo mkdir -p /var/lib/buildvm/secrets/guest-provision
sudo chown root:hermes /var/lib/buildvm/secrets && sudo chmod 0750 /var/lib/buildvm/secrets

# Skip if it exists — regenerating invalidates everything authorized so far.
sudo ssh-keygen -t ed25519 -N '' -C 'buildvm@ai' -f /var/lib/buildvm/secrets/id_ed25519
sudo chmod 0640 /var/lib/buildvm/secrets/id_ed25519
sudo chmod 0644 /var/lib/buildvm/secrets/id_ed25519.pub
```

`buildvm-install.service` grafts `guest-provision/` into `~builder/.ssh` while the VM is stopped.
`known_hosts` must carry the address qemu gives the guest for the host (`10.0.2.2`), or the first
`ssh deployer@ai` stops on a host-key prompt; scanning loopback returns `ai`'s own key, which is the
one that answers there:

```bash
sudo cp /var/lib/buildvm/secrets/id_ed25519 /var/lib/buildvm/secrets/id_ed25519.pub \
      /var/lib/buildvm/secrets/guest-provision/
sudo ssh-keyscan -t ed25519 127.0.0.1 | sed 's/^127\.0\.0\.1/10.0.2.2/' \
      | sudo tee /var/lib/buildvm/secrets/guest-provision/known_hosts >/dev/null
sudo chmod 600 /var/lib/buildvm/secrets/guest-provision/id_ed25519
sudo chmod 644 /var/lib/buildvm/secrets/guest-provision/{id_ed25519.pub,known_hosts}
sudo cat /var/lib/buildvm/secrets/id_ed25519.pub
```

Paste that into `lib/buildvm/default.nix` as `publicKey = "ssh-ed25519 AAAA… buildvm@ai";`. The
placeholder authorizes nothing, so until you replace it the guest boots with no way in.

## 5. Switch `ai`

Commit the pubkey first (flakes only see tracked files):

```bash
sudo nixos-rebuild switch --flake '.#ai'
sudo systemctl restart hermes-agent hermes-backend hermes-webui
journalctl -u buildvm-install -u buildvm -b --no-pager | tail -40
```

This builds two systems: `ai`, and the `buildvm` guest whose kernel/initrd/init/qemu use them plus
the raw image (`nixflakes.buildvm.diskImage`). Expect a big first build (Xfce/tigervnc/browser in
the guest image). `buildvm-install.service` writes the image, grows the ext4 root offline
(`e2fsck -f -y` + `resize2fs`), copies `guest-provision/`, then never touches the guest again — it
skips when the partition already holds a filesystem.

## 6. Check the guest

```bash
sudo ssh -p 2224 builder@127.0.0.1 'echo ok && nix --version && df -h / && uname -a'
sudo ssh -p 2224 builder@127.0.0.1 \
  'git clone ssh://git@git.pleunetowne.com:2223/mitchpleune/nixflakes.git /home/builder/nixflakes'
sudo ssh -p 2224 builder@127.0.0.1 \
  'cd /home/builder/nixflakes && nix eval --accept-flake-config .#nixosConfigurations.ai.config.system.build.toplevel.drvPath'
```

That eval is the real test of §2 — it needs `secrets`, so it proves the guest key works for both
repos. A first-connect ssh failure is usually a missing git-server host key: `ssh-keyscan -p 2223
git.pleunetowne.com` into `~builder/.ssh/known_hosts`.

## 7. Check the gate

```bash
sudo deploy-ai --status
sudo ssh -p 2224 builder@127.0.0.1 'cat /home/builder/deployed-commit'
sudo ssh -p 22 deployer@127.0.0.1 'deploy-ai --status'   # the path the agent uses
sudo deploy-ai --repo ssh://builder@127.0.0.1:2224/home/builder/nixflakes --ref main --dry-run
```

`--status` prints the recorded commit, deployed toplevel, whether the baseline snapshot exists, any
pending rollback, and the allowlist. `/etc/deploy-ai/deployed-commit` holds the flake rev the running
system came from (`-dirty` suffix if you switched from a dirty tree — the gate strips it, and the
content diff still catches the uncommitted part). A real deploy is the dry run without `--dry-run`;
do the first one yourself so you watch: mirror fetch → ancestor check → content diff against
`/etc/deploy-ai/deployed-source` (refuses anything outside `nixflakes.deploy-ai.allowlist`) → build
in the guest → `nix-copy-closure --from builder@127.0.0.1` → health probe of the *current* system →
`systemctl reboot --when=+60m` → switch → wait for health → guard cancelled, or rollback.

If the gate says `no baseline commit recorded`, record one after a switch you did yourself:

```bash
sudo nixos-rebuild switch --flake '.#ai'                    # from a clean commit
echo "$(git rev-parse HEAD)" | sudo tee /var/lib/deploy-ai/commit
```

## 8. Check the agent's terminal

Ask the agent in Hermes to run `pwd && git -C /home/builder/nixflakes log --oneline -3`; it must
return guest output, not "terminal is not available in this execution context". That message meant
one of: no `docker` binary on the unit's PATH (why the docker backend vanished), a sandbox config the
registry rejects, or `execute_code` gated by `approvals.unattended_mode` on the `api_server` surface.
`terminal.backend = "ssh"` needs `ssh_host` + `ssh_user` and a key the guest authorizes — check
`sudo systemctl show hermes-agent -p Environment` and the effective config in `$HERMES_HOME`.
The bot desktop follows the shell backend (`bot_desktop.placement = "auto"`), so Xvnc/Xfce now run
inside the guest with software rendering; set `placement = "gateway"` to move them back to `ai`.

## 9. Reset or shrink the guest

```bash
sudo systemctl stop buildvm
sudo wipefs -a /dev/disk/by-partlabel/buildvm
sudo systemctl restart buildvm-install buildvm     # throws away everything the agent built
```

The partition spans the disk and the installer grows into it, so nothing needs resizing. To hand
space back: stop the guest, `sudo e2fsck -f -y /dev/disk/by-partlabel/buildvm`,
`sudo resize2fs /dev/disk/by-partlabel/buildvm 900G`,
`sudo sgdisk -d 1 -n 1:2048:<last-sector> -c 1:buildvm /dev/sda`, then grow the filesystem again.
Cores/memory come from `nixflakes.virtualisation.buildvm.cpus`/`memoryMiB` (12 / 8192 MiB).

## 10. Roll back to Docker

Everything the agent built on that disk is gone. The btrfs pool must come back with the **same UUID**
— `platforms/ai.nix` mounts `/var/lib/docker` by UUID and `btrfs-docker-quota.service` re-applies the
qgroup cap at boot. Docker cannot enforce a disk quota itself (`--storage-opt size=` is XFS+pquota
only), so the qgroup limit is the cap: writes past 500 GiB fail with EDQUOT instead of filling the
256 GiB ext4 root. It must match `terminal.container_disk = 512000` MB.

```bash
sudo systemctl stop buildvm buildvm-install
sudo wipefs -a /dev/disk/by-partlabel/buildvm
sudo sgdisk --zap-all /dev/sda
sudo sgdisk --new=1:0:0 --change-name=1:storage_pool --typecode=1:linux /dev/sda
sudo mkfs.btrfs -U 9e27c0a6-7a7d-41fe-8e83-0ed124cea728 -L hermes-container /dev/sda1

POOL=/dev/disk/by-uuid/9e27c0a6-7a7d-41fe-8e83-0ed124cea728
sudo mkdir -p /mnt/hermes-container
sudo mount -o subvolid=5 "$POOL" /mnt/hermes-container   # subvolid=5 = the fs tree root
sudo btrfs subvolume create /mnt/hermes-container/docker # becomes /var/lib/docker
sudo btrfs quota enable /mnt/hermes-container            # already enabled → error is informational
sudo btrfs qgroup limit -e 500g /mnt/hermes-container/docker
sudo btrfs qgroup show -reF /mnt/hermes-container
```

Then in `platforms/ai.nix` re-enable `virtualisation.docker.enable`, the `/var/lib/docker` mount unit
and the qgroup service, set `services.hermes-agent.settings.terminal.backend = "docker"`, and drop the
`nixflakes.virtualisation.buildvm` and `nixflakes.deploy-ai` blocks (the gate needs a repo to read, so
it keeps working only if you keep `deployedSource`; `deploy-ai --local` is the mode that needs no VM).
Verify: `findmnt /var/lib/docker && docker info --format '{{.Driver}} {{.DriverStatus}}'`.

## 11. Failure modes

| Symptom | Cause |
| --- | --- |
| `buildvm-install`: `… is not a block device` | §3 not run, or the partition label differs |
| `buildvm: … already holds a filesystem, skipping install` | expected on every boot after the first |
| qemu starts, ssh times out | guest kernel/initrd mismatch, or no `/dev/kvm` (`ls -l /dev/kvm`) |
| guest builds fail on the `secrets` input | §2: guest key is not a deploy key for `secrets.git` |
| gate refuses `outside the deploy-ai allowlist` | correct; the refusal names the nearest allowed prefix — widen `nixflakes.deploy-ai.allowlist` only deliberately |
| gate refuses `does not have the deployed commit … in its history` | ref rebased or unrelated; rebase onto the deployed commit |
| a reboot you did not ask for | the 60-minute guard armed before a switch; `systemctl cancel --when` |
| state to inspect | `/var/lib/deploy-ai/{toplevel,commit,refs.log,lock,rollback-pending,rollback-previous,log/build.log}` |
