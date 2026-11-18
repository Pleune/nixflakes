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

Seeding touches nothing on the network: `buildvm-provision.service` streams `nixflakes` from the
snapshot `ai` was built from and the secrets tree `ai` itself evaluated into `/home/builder/nixflakes`
and `/home/builder/secrets`, and passes `--override-input private /home/builder/secrets`, so the
`private` input never has to be fetched (§6). The guest still needs §2's **read deploy key on
`nixflakes.git`**: provisioning fetches commits through it so the checkout carries the same history as
the dev box, and the agent needs push access to publish what it does there.  Everything else it fetches
itself — `nix flake update`, an added input, `git pull` — goes to the URL left as `origin` too.

### The guest's route out

All of that needs the guest to reach the network, and it does so through qemu's user-mode NAT, not
through anything on your LAN. `buildvm.service` pins the subnet rather than trusting qemu's defaults,
which handed this guest `240.0.0.1/24` with **no default route and no resolver** — every fetch failed
with `connect to address 209.222.120.168 port 2223: Network is unreachable`:

```text
-netdev user,id=n0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15,hostfwd=tcp:127.0.0.1:2224-:22
```

`platforms/buildvm-network.nix` is the guest's half of that and says `networking.useDHCP = false`, a
static `10.0.2.15/24` on `ens3`, gateway `10.0.2.2`, nameserver `10.0.2.3`. It is configured statically
because DHCP is exactly what failed here; the four values are duplicated in the module's `netSubnet`,
`netGateway`, `netDns` and `netGuestAddress` options, so change the two together. NAT means the guest
is a client of `ai`'s connectivity: no inbound except the forwarded ssh port, and qemu's resolver
(`10.0.2.3`) only forwards to `ai`'s own resolver.

Check it from inside the guest:

```bash
ssh -p 2224 builder@127.0.0.1 'ip route; getent hosts git.pleunetowne.com'
```

which should show `default via 10.0.2.2 dev ens3` and an address. Without the `default` line nothing
outbound works, however good the keys are.

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

There are two kinds of key between `ai` and the guest, and only one of them is a secret:

| File | Role |
| --- | --- |
| `ai_buildvm_id_ed25519.age` | private half of the **guest's outbound identity**, encrypted for `ai`'s host ssh key |
| `ai_buildvm_id_ed25519.pub` | its public half, read at eval time by `lib/buildvm/default.nix` |
| `/var/lib/buildvm/keys/<consumer>/id_ed25519` | keypairs `buildvm-install` **generates** for whoever logs into the guest |

`platforms/ai.nix` decrypts the private half with agenix (`nixflakes.agenix.enable`,
`age.secrets."ai_buildvm_id_ed25519"`) into `/run/agenix/ai_buildvm_id_ed25519`, `0600` and root-owned,
and uses it two ways: `nixflakes.deploy-ai.buildKey`, and the key `buildvm-install` grafts into the
guest as `~builder/.ssh/id_ed25519` so the guest authenticates outbound with the identity §2
authorizes.

Nobody else on `ai` can use that file: ssh refuses a private key whose permissions let anyone other
than its owner read it, so the `0640` root:`hermes` version that served every consumer failed as
`Permissions … are too open` / `This private key will be ignored` in the hermes units.  A
group-readable shared key is not a workaround, so each consumer gets a keypair of its own, named
under `nixflakes.virtualisation.buildvm.loginKeys` and generated by `buildvm-install` on its first run:

```nix
nixflakes.virtualisation.buildvm.loginKeys.hermes = {
  path = "/var/lib/buildvm/keys/hermes/id_ed25519";
  owner = "hermes";
  group = "hermes";
};
```

`buildvm-install` chowns each pair to its `owner`, appends every public half — plus the guest's own
public half, so root's `deploy-ai` keeps working — to `~builder/.ssh/authorized_keys` on every pass,
and puts the public halves of the root-owned pairs (plus that same guest key) into the guest's
`/root/.ssh/authorized_keys`.  `buildvm-provision` uses the pair it owns (`provision.loginKey`,
root's own), and Hermes `terminal.ssh_key` points at the `hermes` pair.

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

* `~builder/.ssh/authorized_keys`, `id_ed25519`, `id_ed25519.pub` — the grafted keypair (§4), so the
  guest is reachable and authenticates outbound from its first boot.  Before that, this unit generates
  the host-side login keypairs (§4) and authorizes their public halves here.  `restart
  buildvm-install` re-grafts in place without wiping the guest.

Nothing else is grafted. Repositories and secrets arrive at provisioning time (§6), because only
provisioning knows what this machine runs: a checkout placed here would be whatever branch tip the
source happened to be, and a switch must apply the tree this machine was deployed from.

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

What it does, in order: wait for ssh; skip if `/home/builder/provisioned-commit` already names the
snapshot `ai` runs (that file holds the store name of `provision.sourcePath`, which hashes the tree's
contents, so a changed deploy is never mistaken for the one already applied); stash whatever the agent
left uncommitted (`git stash push -u`, and it has to happen *before* streaming, because streaming
overwrites files in place and stashing afterwards would save the host's tree instead of the agent's);
stream `provision.sourcePath` (the snapshot of the flake `ai` was built from) into `~builder/nixflakes`
and the secrets tree into `~builder/secrets`, both over one `tar` pipe so files land owned by `builder`;
`git init` the checkout if it has no history, point its `origin` at `provision.origin` and fetch it with
`GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'`, refspecs
`+refs/heads/*:refs/remotes/origin/*` and `+refs/tags/*:refs/tags/*` — host branches land under
`origin/*` so the agent's own branches are untouched, and host tags replace the guest's; tag the
applied commit `deployed`;
rebase the guest's `main` onto `deployed` in a scratch worktree (`~builder/nixflakes-rebase`), and if
that rebase cannot be done reset `main` to `deployed` and keep the agent's branch as the tag
`agent-work`; `git checkout --force main` so the tree on disk is the tree being switched; `git stash
apply` the agent's work back; then `nixos-rebuild switch --flake
/home/builder/nixflakes#buildvm --override-input private /home/builder/secrets --accept-flake-config`;
record the snapshot; reboot the guest — qemu restarts it (`buildvm.service` `Restart = always`).

A deploy from a dirty tree records `<sha>-dirty`, which is no commit to check out; the suffix is
stripped, and with nothing left to check out provisioning switches the streamed tree as it stands, which
is exactly what `ai` ran.

The streamed tree has no `.git` — Nix copies tracked files into the store and never the repository — so
the fetch is what makes the checkout comparable to the dev box: `deployed` names the commit `ai` ran,
`origin/main` is what the agent pulls, and its own branches stay its own.  `deployed` is a tag rather
than a branch because a tag is harder for an agent to move by accident: the branch the agent works on is
`main`, and provisioning rebases that onto `deployed` each time.  Divergence is expected — newer commits
on `main`, working-tree edits, both — and the stash/rebase/restore cycle is what keeps it.

A commit that was never pushed is not on the git server, and provisioning says so and switches the
streamed contents anyway: those are exactly what `ai` runs, and inventing a commit on the guest would
make `deployed` mean two different shas on two machines.  Streaming means the contents always match what
`ai` runs, so a stream that fails is fatal — switching whatever was left on disk would provision the
wrong thing — while a fetch that fails is not.

Files the target commit deleted stay on disk as untracked leftovers of the previous deploy — nothing
references them, and cleaning them would delete the agent's own work.

The switch and the reboot run as **root over ssh** (`provision.activationUser`, default `root`), the
file and git work as `builder`.  `builder` has no sudo in the guest — it is in `wheel` only so
`config/nixos/core/nix` trusts `@wheel` as a nix user, and with no password `sudo` simply fails — so
root is the one privileged path.  Both guests set `PermitRootLogin = "prohibit-password"`, and
`buildvm-install` authorizes the root-owned login keys in `/root/.ssh` on every graft pass.

Its ssh uses the keypair `buildvm-install` generates for root (`provision.loginKey`) and trusts the
guest on first use into `/var/lib/buildvm/guest-known_hosts`, its own file rather than root's
`known_hosts`, and `buildvm-install` deletes that file on every pass where it grafts the guest.
So a reseed re-trusts the guest's new sshd keys automatically, while a key that changes under a
running guest still fails as a real warning.  A stale entry in `/root/.ssh/known_hosts` from an
earlier guest does not affect provisioning, but it will break your own `ssh -p 2224`:
`sudo ssh-keygen -R '[127.0.0.1]:2224'`.
So on a fresh disk the first boot ends with
the guest running `platforms/buildvm.nix`: Xfce and Xvnc, nix gc, deploy-rs, and a root filesystem
grown to fill the partition.

```bash
sudo ssh -p 2224 builder@127.0.0.1 'df -h / && findmnt -T /'
sudo ssh -p 2224 root@127.0.0.1 'systemctl is-system-running'
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
pending rollback, and the allowlist. `/etc/deploy-ai/deployed-source` holds the store path of the source
the running system was built from (`nixflakes.deploy-ai.deployedSource`, kept alive by
`system.extraDependencies`), `/etc/deploy-ai/deployed-commit` holds the flake rev the running
system came from (`-dirty` suffix if you switched from a dirty tree — the gate strips it, and the
content diff still catches the uncommitted part). A real deploy is the dry run without `--dry-run`;
do the first one yourself so you watch: mirror fetch → ancestor check → content diff against the
deployed source (refuses anything outside `nixflakes.deploy-ai.allowlist`) → build
in the guest → `nix-copy-closure --from builder@127.0.0.1` → health probe of the *current* system →
`systemctl reboot --when=+60m` → switch → wait for health → guard cancelled, or rollback.

The mirror (`/var/lib/deploy-ai/repo`) is where a candidate commit is looked up, and it is fetched from
the git host on every deploy, so it holds whatever is pushed.  That is the whole reason deploys are
pushed from the dev box: a commit neither ai nor the guest can find is a commit no gate can check.

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
The installer also drops `/var/lib/buildvm/guest-known_hosts` on every pass where it grafts the
guest, because a new image carries new sshd host keys.  The guest grows its own filesystem into the
partition on boot, so nothing needs resizing.  Leave
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
| `buildvm: no partition node for /dev/loop0 p1, skipping grafting` | udev never made the loop partition nodes, so `~builder/.ssh` stays absent — check `losetup -a` for a leftover device |
| `buildvm: no partition labelled buildvm on /dev/loop0, skipping grafting` | the image on the disk has no root carrying that label — a foreign image or a half-written partition; reseed (§9) |
| `buildvm: error: cannot run ssh: No such file or directory` with `fatal: unable to fork` | a unit had no `ssh` in its PATH.  Seeding no longer clones at install time, so expect this only from generations before that fix |
| `buildvm-provision: provision.sourcePath is unset, so there is nothing to put in the guest`, or `nothing to stream from …` | `ai` was not built from a git snapshot, so `deployedSource` (§6) is empty or missing — check the `makeSystem … { deployedSource = … }` call in `flake.nix`.  Provisioning has nothing to put in the guest |
| `buildvm-provision: streaming … failed` | the `tar` pipe to the guest broke mid-transfer (disk full, guest died, ssh dropped).  Provisioning stops rather than switching a half-written tree; `sudo systemctl restart buildvm-provision` re-streams |
| `buildvm-provision: cannot hand /home/builder/nixflakes to builder`, or `/home/builder/nixflakes/.git: Permission denied` followed by `cannot init` | the path exists but belongs to root — generations before provisioning streamed created the checkouts while mounting the image, and sshd logs you in as `builder`, which cannot write there.  Provisioning now hands those directories over as root before streaming, so this row applies to generations before that fix or to a guest where root's authorized key is missing (`sudo ssh -p 2224 root@127.0.0.1 'ls -ld /home/builder/nixflakes'`) |
| `chown: invalid group: 'builder:builder'` inside `cannot hand …` | generations that asked for a group named after the user.  The guest's build user has no such group (NixOS puts `isNormalUser` in `users`), so provisioning now chowns the owner alone |
| `git checkout` / `error: unable to write file …: Permission denied` after streaming | the Nix store is read-only (0444 files, 0555 directories) and tar keeps those modes, so the streamed checkout was unwritable.  Provisioning now runs `chmod -R u+w` on the copy in the guest |
| `buildvm-provision`: `REMOTE HOST IDENTIFICATION HAS CHANGED`, `Offending … key in /root/.ssh/known_hosts:N`, `Host key for [127.0.0.1]:2224 has changed` | an old fingerprint is pinned while the guest's sshd keys are new.  Provisioning pins into `/var/lib/buildvm/guest-known_hosts`, which `buildvm-install` clears on every pass where it grafts the guest, so this row applies to generations before that fix, to a graft pass that found no user to graft, and to your own `ssh`: `sudo rm -f /var/lib/buildvm/guest-known_hosts` or `sudo ssh-keygen -R '[127.0.0.1]:2224'` |
| `buildvm-provision` waits forever, then `start operation timed out`, while `journalctl -u buildvm` shows `BdsDxe: No bootable option or device was found` | the guest is not running an OS, so nothing listens on 2224 and qemu's user-mode networking accepts your connection and resets it, which ssh reports as `kex_exchange_identification: read: Connection reset by peer` rather than "connection refused".  Usually `buildvm-install` never ran this boot, so the disk was never written: `sudo systemctl stop buildvm && sudo systemctl start buildvm-install && sudo systemctl start buildvm`.  If it is in a failed state from an earlier attempt, `sudo systemctl reset-failed buildvm-install` first, and check `journalctl -b -u buildvm-install` for why it stopped early. |
| `buildvm-provision: guest ssh never came up on port 2224` | the guest is not booting (see the qemu rows) or `~builder/.ssh/authorized_keys` was never grafted |
| `buildvm-provision: no commit recorded, switching the streamed tree as it stands` | informational: `provision.targetCommit` is empty (a deploy from a dirty tree, or no `deploy-ai` run yet), so there is nothing to tag or rebase and the streamed contents are switched as they are (§6) |
| `buildvm-provision: could not fetch from ssh://…; the guest keeps whatever commits it already had` | the guest could not reach `provision.origin` with the key `buildvm-install` grafts into `~builder/.ssh`: the deploy key for `nixflakes.git` is not registered (§2), or the guest has no route out.  Check from inside the guest: `ssh -p 2224 builder@127.0.0.1 'ip route; getent hosts git.pleunetowne.com'` must show `default via 10.0.2.2 dev ens3` and resolve, otherwise `buildvm.service` is not passing the pinned `-netdev user,…,net=…,host=…,dns=…` arguments or `platforms/buildvm-network.nix` is not in the guest's config (§2).  Not fatal: the switch runs on the streamed contents |
| `buildvm-provision: could not point /home/builder/nixflakes at ssh://…` | `git remote add`/`set-url` failed, which needs the checkout to be writable (§the permission row above) |
| `buildvm-provision: <sha> is not in the guest's checkout, switching the streamed tree as it stands` | informational: that commit is not pushed to `origin`, so nothing is tagged or rebased and the guest switches the streamed contents, which are what `ai` runs.  Push the deploy (§7) and the next pass brings the history; `sudo ssh -p 2224 builder@127.0.0.1 'git -C /home/builder/nixflakes log --oneline -3 && git -C /home/builder/nixflakes tag -l'` shows what is there |
| `buildvm-provision: could not tag <sha> as deployed`, `could not create main at <sha>`, or `could not reset main to deployed` | the checkout is not writable or is in a state git will not accept; `sudo ssh -p 2224 builder@127.0.0.1 'git -C /home/builder/nixflakes status --short'`.  Provisioning stops rather than switching a checkout it cannot describe |
| `buildvm-provision: could not create the rebase worktree at /home/builder/nixflakes-rebase; leaving main as it is` | the scratch worktree could not be made (leftover directory, or `main` missing).  `main` keeps whatever the agent had, so the applied commit is still tagged `deployed` and the switch evaluates the streamed tree |
| `buildvm-provision: main rebased onto deployed` | the normal case: the agent's commits sit on top of the applied commit (§6) |
| `buildvm-provision: main would not rebase onto deployed; main reset, the guest's work kept on tag agent-work (<sha>)` | the agent's branch and the applied commit cannot be rebased cleanly.  What runs is the host's config; the agent's branch is intact at `agent-work`, so `sudo ssh -p 2224 builder@127.0.0.1 'git -C /home/builder/nixflakes log --oneline agent-work -5'` is the way back to it |
| `buildvm-provision: the guest's stashed changes do not apply onto the applied tree; kept in the stash` | the agent's edits conflict with the new tree.  They stay in `git stash list` rather than being merged by hand, and tracked files are reset so the switch evaluates a clean tree |
| `buildvm-provision: could not stash the guest's uncommitted changes; streaming will overwrite them` | `git stash` refused (usually an unborn `HEAD` in a freshly initialized checkout).  Streaming continues, so those edits are lost — read them off the guest first if they matter |
| `buildvm-provision: could not check out main in /home/builder/nixflakes` | the checkout exists but the forced checkout failed; `sudo ssh -p 2224 builder@127.0.0.1 'git -C /home/builder/nixflakes status --short'` |
| `buildvm-provision: switch failed; guest left as it is` | read the `nixos-rebuild` output in `journalctl -u buildvm-provision -b`; the guest keeps the system it had |
| `buildvm-provision: guest did not come back after the switch` | the new system does not boot — the switch rewrote the ESP entries. Boot the previous loader entry from the guest's serial console (`journalctl -u buildvm -b`), or reseed (§9) |
| `journalctl -b -u switch-to-configuration`: `[agenix] decrypting …` then `chmod: cannot access '/run/agenix.d/N/<name>.tmp': No such file or directory`, `mv: cannot stat …`, `Activation script snippet 'agenixInstall' failed (1)` | no identity in `config.age.identityPaths` could open the file, i.e. the secret is encrypted for a different key. Nothing else reports this, and the activation errors are not fatal, so the switch finishes with an empty `/run/agenix`. Re-encrypt for `ssh -p … 'cat /etc/ssh/ssh_host_ed25519_key.pub'` (§4) |
| the guest stays the seed image (no Xfce, no activated config) | provisioning never ran or failed: `systemctl status buildvm-provision`; its `ConditionPathExists` means `provision.loginKey` must exist, which `buildvm-install` generates — `ls -l /var/lib/buildvm/keys/provision` |
| `buildvm-provision`: `Permission denied (publickey)` from the switch, while the builder-side checks work | the guest's `/root/.ssh/authorized_keys` has no root-owned key, i.e. the running guest predates the root graft or `buildvm-install` never ran after it: `sudo ssh -p 2224 root@127.0.0.1 true`, then `sudo systemctl restart buildvm-install`.  `builder` cannot do this work — it has no sudo, by design |
| Hermes terminal: `Load key "…": Permission denied`, then `Permission denied (publickey)` | the unit's own key is missing or unreadable — Hermes uses `/var/lib/buildvm/keys/hermes/id_ed25519`, which `buildvm-install` creates, so `ls -l /var/lib/buildvm/keys/hermes` and `systemctl status buildvm-install` first.  `Permission denied (publickey)` with a readable key means the guest does not authorize it: the pass that generated it did not graft (`journalctl -u buildvm-install -b`) |
| ssh says `Permissions … for '<key>' are too open` / `This private key will be ignored` | ssh refuses a private key that someone other than its owner can read.  `buildvm-install` writes every key it generates `0600` to its own `owner` and the agenix secret `0600 root`, so this means something rewrote them, or a unit is pointed at a key it does not own: `ls -l <key>` and `sudo chmod 600 <key>`, or give that consumer its own `loginKeys` entry |
| qemu: `pflash: file … does not exist` | `/var/lib/buildvm/efi-vars.fd` was deleted and `buildvm.service` started before `buildvm-install.service` seeded it — `systemctl start buildvm-install` |
| guest drops to the UEFI shell / `Boot Failed` | no NVRAM entry and no ESP fallback path; the fallback needs `EFI/BOOT/BOOTX64.EFI` on the ESP, so re-run the bootloader phase in the guest (`nixos-rebuild switch --bootloader-only`) or reset `/var/lib/buildvm/efi-vars.fd` |
| qemu starts, ssh times out | no `/dev/kvm` (`ls -l /dev/kvm`), or no loader on the ESP — read `journalctl -u buildvm -b`, which shows the guest's serial console |
| guest sits in Emergency Mode | root is named by the ext4 label `buildvm`; a stale filesystem or a label from another image leaves `/dev/disk/by-label/buildvm` unresolvable |
| a guest build *you* run fails on the `secrets` input | it fetched the input over ssh: §2 (deploy key) plus `known_hosts` for port 2223. Provisioning avoids this with `--override-input private` (§6) |
| gate refuses `outside the deploy-ai allowlist` | correct; the refusal names the nearest allowed prefix — widen `nixflakes.deploy-ai.allowlist` only deliberately |
| gate refuses `does not have the deployed commit … in its history` | ref rebased or unrelated; rebase onto the deployed commit |
| a reboot you did not ask for | the 60-minute guard armed before a switch; `systemctl cancel --when` |
| state to inspect | `/var/lib/deploy-ai/{toplevel,commit,refs.log,lock,rollback-pending,rollback-previous,log/build.log}` |
