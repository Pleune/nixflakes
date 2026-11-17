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
| `ai` → guest: `ssh -p 2224 builder@127.0.0.1`, Hermes `terminal.ssh_key`, `buildvm-provision.service` | guest authorizes the public half; the install unit does this |
| guest → git host: `nixflakes.git`, and `secrets.git` for anything that fetches the `private` input itself | **read deploy keys**, plus push on `nixflakes.git` — only for what the agent runs itself (`git pull`, `nix flake update`, pushes) |
| `ai` root: the gate's fetch of the repo it deploys (`nixflakes.deploy-ai.buildKey`) | host authorizes the public half (`publicKey`), already wired |

Neither seeding nor the guest's own switch touches the git host: `buildvm-install.service` clones
`nixflakes` from the mirror `deploy-ai` already keeps on `ai`, copies the secrets tree `ai` itself
evaluated into `/home/builder/secrets`, and `buildvm-provision.service` passes
`--override-input private /home/builder/secrets`, so the `private` input resolves from disk. What still
needs §2 is anything the guest fetches for itself, because those go to the URL left as `origin`.

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
(`buildvm-install.service` writes a bootable image onto it — a GPT with an ESP labelled `ESP` and an
ext4 root labelled `buildvm`), so the host mounts nothing here and never resizes it. The image's own
partition table lives *inside* this partition, and Linux does not scan inside partitions, so the host
never sees `buildvm`'s ESP or root; only the loop device in §9 does.

Wipe the old signatures, not just the partition table: a leftover filesystem on the partition is what
made the installer think the guest was already installed.

## 4. Keypair: the secrets repo, agenix, and what the guest gets

There is one ai ↔ buildvm keypair, and it lives in the **secrets repo**, not on disk:

| File | Role |
| --- | --- |
| `ai_buildvm_id_ed25519.age` | private half, encrypted for `ai`'s host ssh key |
| `ai_buildvm_id_ed25519.pub` | public half, read at eval time by `lib/buildvm/default.nix` |

`platforms/ai.nix` decrypts the private half with agenix (`nixflakes.agenix.enable`,
`age.secrets."ai_buildvm_id_ed25519"`) and hands the resulting path — `/run/agenix/ai_buildvm_id_ed25519`,
mode `0640`, group `hermes` — to everything that sshes to the guest: `nixflakes.virtualisation.buildvm.privateKeyPath`,
`nixflakes.deploy-ai.buildKey`, and Hermes `terminal.ssh_key`.  Group `hermes` rather than root-only
`0600` because the gateway and dashboard units run as `User=hermes`.

agenix decrypts with `config.age.identityPaths`, whose default is `/etc/ssh/ssh_host_ed25519_key`, so
`ai` needs nothing beyond that host key and a secret encrypted for it:

```bash
# On your workstation: the pubkey to encrypt for, and the check that the secret opens there.
ssh ai 'cat /etc/ssh/ssh_host_ed25519_key.pub'
age -d ai_buildvm_id_ed25519.age | ssh-keygen -yf -   # must print ai_buildvm_id_ed25519.pub
```

Commit both files to the secrets repo, then point this flake at that revision:

```bash
cd nixflakes && nix flake update private
nix eval --accept-flake-config .#nixosConfigurations.buildvm.config.users.users.builder.openssh.authorizedKeys.keys
```

That eval reads the `.pub` through the `private` input, so it is the test that the lock file carries a
revision with the files in it. `platforms/buildvm-bootstrap.nix` deliberately evaluates *without*
`private`, so the seed image authorizes no key of its own; `buildvm-install.service` puts the keypair
into `~builder/.ssh` while the VM is stopped (§5), which is why the guest is reachable from its very
first boot.

The guest gets the private half as its own `~builder/.ssh/id_ed25519`, so outbound ssh from the guest
authenticates with the identity §2 already authorizes. Nothing else is grafted: `known_hosts` is not
written, because provisioning never contacts the git host (§2), and the first real ssh from the guest
to `git.pleunetowne.com:2223` should be answered with `ssh-keyscan -p 2223 git.pleunetowne.com >>
~builder/.ssh/known_hosts`.

## 5. Seed the guest, then switch `ai`

Commit the key files in the secrets repo first (§4) — flakes only see what the lock file points at.
The seed image is built by `make-disk-image`, which boots a throwaway VM under OVMF to install
systemd-boot onto the ESP it creates, so build it on a KVM host — here, on `ai` itself:

```bash
nix build --accept-flake-config '.#nixosConfigurations.buildvmBootstrap.config.system.build.diskImage'
ls -lh result          # a directory containing nixos.img
sudo nixos-rebuild switch --flake '.#ai'
sudo systemctl restart hermes-agent hermes-backend hermes-webui
journalctl -u buildvm-install -u buildvm -u buildvm-provision -b --no-pager | tail -40
```

`--flake '.#ai'` builds `ai` and the seed image and nothing else: the guest's own system is no longer
part of the host build, and no kernel, initrd or guest closure is rooted in ai's store. Once the
partition is written, the seed image is an ordinary unrooted store path, so `nix gc` reclaims it.

`buildvm-install.service` writes the image's `nixos.img` onto the partition and then grafts, on every
start, everything the guest needs but cannot fetch itself:

* `~builder/.ssh/authorized_keys`, `id_ed25519`, `id_ed25519.pub` — the shared keypair (§4), so the
  guest is reachable and authenticates outbound from its first boot.  `restart buildvm-install`
  re-grafts in place without wiping the guest.
* `~builder/nixflakes`, cloned from the bare mirror `deploy-ai` maintains at `/var/lib/deploy-ai/repo`,
  so the guest starts on the repository `ai` was last deployed from.  Only the *first* clone touches
  the guest's home, so the agent's own checkout is never overwritten, and `origin` is set to the real
  URL — which is what a `git pull` or a push then uses.
* `~builder/secrets`, a plain copy of the secrets tree `ai` evaluated, refreshed on every start.  It
  is not a git checkout: the guest reads the same secrets `ai` used and needs no key for that repo.

Nothing resizes anything on the host — the guest grows its own root partition and filesystem on its
first boot (`boot.growPartition`), which is why a seed image sized to its own closure lands on a
1.82 TiB disk. The unit also seeds `/var/lib/buildvm/efi-vars.fd` from `pkgs.OVMF.variables` the first
time, because qemu's writable pflash unit needs an existing file of the firmware's own size.

qemu boots the disk as UEFI (`pkgs.OVMF` firmware, no `-kernel`/`-initrd`/`-append`): OVMF loads the
kernel's EFI stub through systemd-boot, which reads its entries from the ESP, and the seed carries
only systemd, nix, git and sshd. `buildvm-provision.service` (§6) installs the real guest from inside
it: the switch rewrites the loader entries and copies the new kernel onto the guest's own ESP, so the
boot chain survives it.

## 6. The guest's own system, and checking it

`buildvm-provision.service` runs once per boot, after the VM is up, and applies the guest's own NixOS
config *inside* the guest:

```bash
sudo ssh -p 2224 builder@127.0.0.1 'echo ok && nix --version && df -h / && uname -a'
journalctl -u buildvm-provision -b --no-pager | tail -30
sudo ssh -p 2224 builder@127.0.0.1 'cat /home/builder/provisioned-commit'
```

What it does, in order: wait for ssh; read the commit to apply (`/home/builder/deployed-commit`, the
one `deploy-ai` recorded, falling back to the checkout's HEAD); skip if
`/home/builder/provisioned-commit` already names it; `git checkout --detach` that commit in the
guest's clone (the branch tip there can be ahead of or behind what ai runs, so the switch must not
trust HEAD); then `sudo nixos-rebuild switch --flake
/home/builder/nixflakes#buildvm --override-input private /home/builder/secrets --accept-flake-config`;
record the commit; reboot the guest — qemu restarts it (`buildvm.service` `Restart = always`).
`builder` is in `wheel` with NOPASSWD sudo, which is what makes that possible and also makes it a nix
trusted user (`config/nixos/core/nix` trusts `@wheel`).  So on a fresh disk the first boot ends with
the guest running `platforms/buildvm.nix`: Xfce and Xvnc, nix gc, deploy-rs, and a root filesystem
grown to fill the partition.

```bash
sudo ssh -p 2224 builder@127.0.0.1 'df -h / && findmnt -T /'
sudo ssh -p 2224 builder@127.0.0.1 'sudo -n systemctl is-system-running'
```

To test that the guest can reach the git host on its own — the thing provisioning deliberately avoids
— evaluate an input it has to fetch:

```bash
sudo ssh -p 2224 builder@127.0.0.1 \
  'cd /home/builder/nixflakes && nix eval --accept-flake-config .#nixosConfigurations.ai.config.system.build.toplevel.drvPath'
```

That needs the `private` input over ssh — read access to `secrets.git` — which is exactly what
provisioning avoids by overriding the input. It therefore proves §2 and §4 for the guest key. A
first-connect failure is the missing git-server host key:
`ssh-keyscan -p 2223 git.pleunetowne.com >> /home/builder/.ssh/known_hosts`.

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

`wipefs` clears the image's GPT signature, which is what makes the installer write the seed again.
The guest grows its own filesystem into the partition on boot, so nothing needs resizing.  Leave
`/home/builder/provisioned-commit` alone and the reseeded guest re-applies the same commit on its next
boot, which is what you want after wiping the disk.  To hand
space back: stop the guest, shrink the inner root partition instead of the disk —
`LOOP=$(sudo losetup -f --show -P /dev/disk/by-partlabel/buildvm)` (`-P` is what makes
`"$LOOP"p1`/`"$LOOP"p2` exist, where p1 is the ESP and p2 the root), `sudo e2fsck -f -y "$LOOP"p2`,
`sudo resize2fs "$LOOP"p2 900G`, `sudo parted "$LOOP" resizepart 2 900G`, then
`sudo losetup -d "$LOOP"`. To reset the guest's firmware state (its NVRAM boot entries), delete
`/var/lib/buildvm/efi-vars.fd`; `buildvm-install.service` seeds a fresh copy next start.

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
| `buildvm: no *.img inside /nix/store/…-buildvm-bootstrap` | `image` was pointed at something other than the `make-disk-image` output directory |
| `buildvm: … already partitioned, skipping install` | expected on every boot after the first; `wipefs -a` the partition (§9) to reseed |
| `buildvm: no partition node for /dev/loop0 p1, skipping grafting` | udev never made the loop partition nodes; the guest still boots, but `~builder/.ssh` and the repo checkouts stay absent — check `losetup -a` for a leftover device |
| `buildvm: no partition labelled buildvm on /dev/loop0, skipping grafting` | the image on the disk has no root carrying that label — a foreign image or a half-written partition; reseed (§9) |
| `buildvm: error: cannot run ssh: No such file or directory` with `fatal: unable to fork` | the install unit had no `ssh` in its PATH, so any clone that had to reach the git host died there.  Seeding now clones from `/var/lib/deploy-ai/repo` and needs no ssh, so expect this only from generations before that fix |
| `buildvm: builder: no local source for nixflakes, falling back to its url` | `/var/lib/deploy-ai/repo` does not exist yet — no deploy has run since the guest started being seeded from it.  The fallback clone needs `ai` to reach the git host with the keypair (§2/§4) |
| `buildvm: clone of /var/lib/deploy-ai/repo into nixflakes failed` | the mirror exists but has no branches yet — run a `deploy-ai` so its fetch populates it, then `sudo systemctl restart buildvm-install` |
| `buildvm: copy of secrets from /nix/store/… failed` | the tree `ai` evaluated is no longer in its store; re-evaluate and `sudo systemctl restart buildvm-install` |
| `buildvm-provision: guest ssh never came up on port 2224` | the guest is not booting (see the qemu rows) or `~builder/.ssh/authorized_keys` was never grafted |
| `buildvm-provision: no commit to apply (missing /home/builder/nixflakes?)` | the clone never happened — check the install unit's log and that `/var/lib/deploy-ai/repo` has branches |
| `buildvm-provision: … is not in the guest's checkout` | `/home/builder/deployed-commit` names a commit the guest's clone predates.  Every `deploy-ai` run fetches the mirror the clone came from; to bring an existing checkout forward, run `git -C ~/nixflakes fetch origin` inside the guest (that needs §2) or reseed (§9), which re-clones from the mirror |
| `buildvm-provision-start: line N: private: command not found` | `OVERRIDE` was assigned unquoted, so the shell ran `private` as a command. Fixed by quoting the value; only generations before that fix hit it |
| `buildvm-provision: could not check out <sha> in /home/builder/nixflakes` | the guest's clone is dirty or the commit vanished; `sudo ssh -p 2224 builder@127.0.0.1 'git -C /home/builder/nixflakes status --short'` |
| `buildvm-provision: switch failed; guest left as it is` | read the `nixos-rebuild` output in `journalctl -u buildvm-provision -b`; the guest keeps the system it had |
| `buildvm-provision: guest did not come back after the switch` | the new system does not boot — the switch rewrote the ESP entries. Boot the previous loader entry from the guest's serial console (`journalctl -u buildvm -b`), or reseed (§9) |
| the guest stays the seed image (no Xfce, no sudo) | provisioning never ran or failed: `systemctl status buildvm-provision`; its `ConditionPathExists` means the agenix secret must exist — `ls -l /run/agenix/ai_buildvm_id_ed25519` |
| Hermes terminal: `Load key "…": Permission denied`, then `Permission denied (publickey)` | the agenix secret is not `0640 root:hermes`, or `/run/agenix/ai_buildvm_id_ed25519` is missing because decryption failed. Decryption happens in the activation script, not in a unit, so read `journalctl -b -u switch-to-configuration --no-pager | grep -A2 agenix`; it fails when `config.age.identityPaths` (default `/etc/ssh/ssh_host_ed25519_key`) is not a key the secret is encrypted for |
| qemu: `pflash: file … does not exist` | `/var/lib/buildvm/efi-vars.fd` was deleted and `buildvm.service` started before `buildvm-install.service` seeded it — `systemctl start buildvm-install` |
| guest drops to the UEFI shell / `Boot Failed` | no NVRAM entry and no ESP fallback path; the fallback needs `EFI/BOOT/BOOTX64.EFI` on the ESP, so re-run the bootloader phase in the guest (`nixos-rebuild switch --bootloader-only`) or reset `/var/lib/buildvm/efi-vars.fd` |
| qemu starts, ssh times out | no `/dev/kvm` (`ls -l /dev/kvm`), or no loader on the ESP — read `journalctl -u buildvm -b`, which shows the guest's serial console |
| guest sits in Emergency Mode | root is named by the ext4 label `buildvm`; a stale filesystem or a label from another image leaves `/dev/disk/by-label/buildvm` unresolvable |
| a guest build *you* run fails on the `secrets` input | it fetched the input over ssh: §2 (deploy key) plus `known_hosts` for port 2223. Provisioning avoids this with `--override-input private` (§6) |
| gate refuses `outside the deploy-ai allowlist` | correct; the refusal names the nearest allowed prefix — widen `nixflakes.deploy-ai.allowlist` only deliberately |
| gate refuses `does not have the deployed commit … in its history` | ref rebased or unrelated; rebase onto the deployed commit |
| a reboot you did not ask for | the 60-minute guard armed before a switch; `systemctl cancel --when` |
| state to inspect | `/var/lib/deploy-ai/{toplevel,commit,refs.log,lock,rollback-pending,rollback-previous,log/build.log}` |
