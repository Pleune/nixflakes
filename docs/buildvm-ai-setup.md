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

Provisioning needs nothing on the network to put secrets in the guest: `buildvm-provision.service`
copies the secrets tree `ai` itself evaluated into `/home/builder/secrets` and passes
`--override-input private /home/builder/secrets`, so the `private` input never has to be fetched (§6).
The nixflakes tree reaches `/home/builder/nixflakes` only when that checkout has no commits, which
seeds it (§6); every other pass leaves those files alone. The guest still needs §2's **read deploy key on
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
-device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56
```

The guest's half of that lives in `platforms/buildvm.nix` and `platforms/buildvm-bootstrap.nix` — each
spells it in full, because a platform file is a single-file definition of an OS install.  Both say
`networking.useNetworkd = true`, `networking.useDHCP = false`, and write one network unit that matches
the pinned MAC and carries `10.0.2.15/24`, gateway `10.0.2.2` and resolver `10.0.2.3`. Three things in
it are load-bearing:

- `useNetworkd`, because a static address is only applied by whoever manages the interface. With
  `useNetworkd = false` plus `useDHCP = false` nobody does, `systemd.network.networks` evaluates to
  `{ }`, and the card comes up with no address at all — the forwarded ssh port hangs in exactly the
  way §11 describes.
- **Matching by MAC rather than interface name.** Predictable names are not stable across generations
  of this VM: one boot named the card `ens3`, the next `enp0s3`. A unit matched on `ens3` simply stops
  matching, and that failure is silent — `ip a` shows the card `state DOWN` with no address, while
  `nc -z 127.0.0.1 2224` still says the port is open because qemu accepts the connection locally.
  qemu pins the MAC through `netGuestMac`, so this match cannot drift.
- Static addressing rather than DHCP, because DHCP is what failed here, and `Gateway`/`DNS` inside the
  unit rather than `networking.defaultGateway`/`networking.nameservers`, because those options are
  keyed on interface names.

`netSubnet`, `netGateway`, `netDns`, `netGuestAddress` and `netGuestMac` mirror those values on the
host side, so change the two together. NAT means the guest is a client of `ai`'s
connectivity: no inbound except the forwarded ssh port, and qemu's resolver (`10.0.2.3`) only forwards
to `ai`'s own resolver.

Check it from inside the guest:

```bash
ssh -p 2224 builder@127.0.0.1 'ip route; getent hosts git.pleunetowne.com'
```

which should show `default via 10.0.2.2 dev <interface>` and an address on `10.0.2.15/24`. The
interface name is whatever predictable naming gives this boot (`ens3`, `enp0s3`, …) — the unit matches
the pinned MAC, so the name is not the thing to check. Without the `default` line nothing outbound
works, however good the keys are.

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
| `ai_buildvm_id_ed25519.pub` | its public half, read at eval time by `platforms/ai.nix` and `platforms/buildvm.nix` |
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

`buildvm-install` chowns each pair to its `owner`, appends every public half to
`~builder/.ssh/authorized_keys` on every pass, and puts the public halves of the **root-owned** pairs
into the guest's `/root/.ssh/authorized_keys`.  The guest's own outbound keypair is *not* one of these:
`buildvm-install` installs its public half as `~builder/.ssh/id_ed25519.pub` and leaves it out of
`authorized_keys`, because a key the guest already holds would authorize logins into the guest — the
wrong direction for a deploy key pointed at the git host.  `buildvm-provision` uses the pair it owns
(`provision.loginKey`, root's own), and Hermes `terminal.ssh_key` points at the `hermes` pair.

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
authenticates with the identity §2 already authorizes.  Nothing else is grafted: no `known_hosts` is
written into the image.  Provisioning's own fetch trusts the git host on first use
(`StrictHostKeyChecking=accept-new`, §6), which is deliberate — a pinned file baked into a store-built
image would go stale the moment the server's key changes.  To pin it anyway, run `ssh-keyscan -p 2223
git.pleunetowne.com >> /home/builder/.ssh/known_hosts` in the guest once.

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
That `nixos-rebuild` is the operator's switch: it runs from a working tree on `ai`, needs no gate, and
is how the first deploy and every emergency happens.  After it, `ai` records what it runs (§7), and
the agent's own deploys go through the gate instead — *The agent's route onto `ai`*, below.

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

### The agent's route onto `ai`

There is no repository on `ai`, and `builder` has no route to `ai`'s root (§4, §8).  The agent's
deploy is a patch on stdin to the `deployer` account:

```bash
cd /home/builder/nixflakes
git add -A && git commit -m 'guest: …'
git format-patch --stdout deployed..main | ssh -p 22 deployer@10.0.2.2 'deploy-ai --submit'
```

`deployed` is the tag provisioning moves to the commit `ai` runs (§6), so `deployed..main` is the
agent's own work and nothing else.  `10.0.2.2` is qemu's gateway — `ai` as the guest sees it — and
port 22 is ai's own sshd, not the 2224 forward that runs the other way and reaches the guest (§6).
The grafted key in `~builder/.ssh` (§4) is the half `nixflakes.deploy-ai.publicKey` authorizes for
`deployer`, so no `-i` is needed.

`deployer` cannot open a shell.  Its login shell is `deploy-ai-gate`
(`modules/nixos/deploy-ai/default.nix`), which accepts only `deploy-ai …` and runs it as root through
`/run/wrappers/bin/sudo`, the setuid copy `security.wrapperDir` provides, under a `NOPASSWD` sudo rule
scoped to `/run/current-system/sw/bin/deploy-ai`.  The module asserts `config.security.sudo.enable`,
because that option is what puts the setuid copy there (§7).  A submitted series arrives
as `deploy-ai --submit` with the patch on stdin.  Both halves are in `pkgs/deploy-ai/`: the tool is
`deploy-ai.py`, stdlib-only Python with its tests in `test-deploy-ai.py`, and the login shell is the
shell script `gate.nix`.

Nothing the guest sent is trusted as a tree.  `deploy-ai` unpacks `/etc/deploy-ai/deployed-source`
— the snapshot `ai` was built from (§7) — applies the series onto it with `git apply`, and vets the
result:

* `nixflakes.deploy-ai.allowlist` — the same scope rule `--repo`/`--ref` uses (§7).
* `nixflakes.deploy-ai.submit.denylist` — the deployment machinery itself: the gate's module, its
  script, `flake.lock`, `secrets/`.  A patch touching one is refused, because the thing doing the
  vetting cannot vet a change to itself.
* `nixflakes.deploy-ai.policyDigest` — the check under *The policy digest* below.
* `nixflakes.deploy-ai.submit.maxBytes` (262144 here) — the series lands in
  `/var/lib/deploy-ai/inbox`, `0700 root`, as the record of what arrived, readable only by root.

**What a submission switches.**  Every submission takes the one path from §7: build `ai`'s system on
`ai`, health probe the system running now, arm the timed reboot guard, switch, and roll back if the
probes go red.  A patch to the guest's own files is no different and no safer: `platforms/buildvm.nix`
describes a configuration *object* on `ai`, not a system `ai` runs, so building and switching `ai`
takes it without touching the api server, and `buildvm-provision` builds that same tree inside the guest
on its next pass (§6, §8).  Nothing crosses between the two stores, and nothing is switched in the guest
from here.

That one keypair is the gate's only route into the VM, and it is neither of the keys the guest already
holds.  `nixflakes.deploy-ai.buildKey` is `nixflakes.virtualisation.buildvm.loginKeys.deploy-ai.path` —
`/var/lib/buildvm/keys/deploy-ai/id_ed25519`, a root-owned login keypair `buildvm-install` generates
and whose public half it grafts into the guest's `~builder/.ssh/authorized_keys`.  It is authorized as
`builder` only: `loginKeys.deploy-ai.guestRoot = false` keeps it out of the guest's
`/root/.ssh/authorized_keys`, because the gate reads from the VM and never switches it, so a root login
there would be a second way in that nothing uses (§4).  `/etc/deploy-ai/build-key` publishes only that
path, so the tool reads the VM over `127.0.0.1:2224`, on the same forward Hermes' shell uses, without
ever naming a buildvm path in its own source.
It is deliberately not the guest's outbound keypair (`nixflakes.virtualisation.buildvm.privateKeyPath`, the
agenix file `/run/agenix/ai_buildvm_id_ed25519`): that one authenticates the guest *toward* the git
host, and offering it inbound is the wrong direction — sshd in the guest has never been configured to
accept it.  Nor is it `provision.loginKey`: provisioning owns that one, and it is the only key with a
reason to hold root in the guest.
Every guest ssh sets `UserKnownHostsFile=/dev/null` with `StrictHostKeyChecking=accept-new`, because
re-seeding the disk replaces the guest's sshd host keys and a remembered key is a hard refusal.

**The policy digest.**  `nixflakes.deploy-ai.policyDigest` is a sha256 of everything a patch must not
be able to move: the allowlist, the gate's key, the build key, the state dir, the submit cap, the build
cap, the private input the gate overrides instead of fetching, the denylist, the sudo rules, the users
and their authorized keys, sshd's settings, nix's `trusted-users`, and the buildvm paths provisioning
switches on.  `ai` writes its own digest to `/etc/deploy-ai/policy-digest`, and `deploy-ai` evaluates
the same option out of the patched tree.
A submission whose digest differs is refused before anything is built or applied.  The denylist alone
cannot do this: a digest move is legal inside an allowed prefix, so the digest is what stops a patch
rewriting the rules it is vetted against.

**Rehearsal.**  `--vet` runs every check above and applies nothing:

```bash
git format-patch --stdout deployed..main | ssh -p 22 deployer@10.0.2.2 'deploy-ai --vet'
```

It reports one row per check as that check passes — size against the cap, whether the series applies,
scope, denylist, `policy unchanged`, the class, one row per changed path, and what a real submit would
then do.  Every run closes with `result: ok`, `result: applied`, `result: refused`, or `result: failed`,
so a script never has to parse prose, and a refusal lands after the rows that held.  `deploy-ai
--submit --dry-run` is the same report.  Run `--vet` first and send `--submit` only when the printed
class is the one you expected.  The policy digest itself is not printed: it is fixed on `ai`, no patch
can move it, and a hash an agent cannot act on is only noise.

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
contents, so a changed deploy is never mistaken for the one already applied); copy `provision.sourcePath`
and the `private` source into the **guest's own store** with `nix copy --no-check-sigs
--to ssh-ng://root@127.0.0.1:2224`, because a store path on `ai` is invisible to the guest and everything
below reads it locally; pin both of those paths under `/nix/var/nix/gcroots/deploy-ai` in the guest, which
`platforms/buildvm.nix` garbage-collects daily and which nothing else points at yet; copy the secrets tree
out of the store into `~builder/secrets`, because secrets are a plain tree and the agent has to be able to
read them; `git init -q -b main` the checkout if it has
no repository, point its `origin` at
`provision.origin` and fetch it with
`GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'`, refspecs
`+refs/heads/*:refs/remotes/origin/*` and `+refs/tags/*:refs/tags/*` — host branches land under
`origin/*` so the agent's own branches are untouched, and host tags replace the guest's; if the
repository has **no commits at all**, seed it from the copied `provision.sourcePath` and commit that as
`buildvm-provision: seeded from ai`, which is the only time provisioning writes files into
`~builder/nixflakes`;
choose a commit to record — `provision.targetCommit`, else what deploy-ai recorded in
`/home/builder/deployed-commit`, with the `-dirty` suffix stripped, when that commit exists in the
checkout, else the seeded commit, else a commit it publishes for the occasion; then run
`nixos-rebuild switch --flake '"$deployedSource"#buildvm' --override-input private
/home/builder/secrets --accept-flake-config --no-write-lock-file`; only after the switch succeeds move
the tag `deployed` to the recorded commit and push `refs/tags/deployed` to `origin` (a refusal there is a
warning, not a failure); write `~builder/nixflakes/DEPLOYED.md`; record the snapshot; reboot the guest
— qemu restarts it (`buildvm.service` `Restart = always`).

The switch names `ai`'s store path because the copy above put that exact path in the guest.  Before the
copy existed, a switch naming it died with `error: getting status of
"/nix/store/…-nixflakes-source": No such file or directory` — store paths are host-local — and switching
a streamed copy instead meant committing that copy first, which invented a commit nobody deployed.  A
store path is content-addressed, so the copy is the same bytes `ai` evaluated, with no re-serialization
and no tree of the agent's working files to exclude.

The pin is two symlinks named `source` and `secrets`, rewritten on every pass.  The guest collects paths
nothing refers to, and for the minutes between the copy and a switch the only thing referring to that tree
is this unit's own command line, so a collection landing there would delete the tree mid-switch.  Because
the names are fixed, repointing them leaves the previous snapshot unrooted and collectable: the guest holds
the tree it is being asked to run, not every tree it has ever been given.

The commit it records is a label, and it is not always a commit the guest has.  A ref naming a commit the
guest cannot resolve used to make `nixos-rebuild` fall back to whatever `main` already was, which looked
exactly like the VM ignoring the deploy — so a recorded sha is used only when `git cat-file -e` confirms
it, and otherwise the pass commits the copied tree in `~builder/nixflakes-scratch`, pushes it as
`refs/tags/provisioned-snapshot`, and records that sha.  Records and `git rebase deployed` want a sha;
what gets built is the path.

Provisioning never touches the agent's files, its `main`, or its `HEAD`: no `git stash`, no
`checkout --force`, no `update-ref`.  An earlier generation reset `main` to the deployed commit on every
pass, which deleted commits the agent had not pushed, and work that never left the guest cannot be
recovered.  What the guest builds is `ai`'s store path, outside the checkout, so the agent's
working tree cannot be part of it; the commit above is only a label for the tag
and the records.  What moves on a deploy is one tag.

That also removes the old problem with deleted files.  The switch builds `ai`'s store path, whose contents
are exactly what `ai` was built from, so the leftover of a renamed file in the checkout is not part of
what gets built.

The commit is a label, not the build input, and it often cannot be a real one.  `flake.nix` records
`deployedCommit` as `self.rev or self.dirtyRev`, which is empty for a deploy made from a dirty tree, and
a gate submission is reconstructed on `ai` into a commit that exists only in `ai`'s retained base
repository.  Either way the guest still switches to `ai`'s tree; what it tags, and what
`/home/builder/deployed-commit` holds, is then the commit provisioning published, not `ai`'s sha.
`git push origin main` from the guest is what makes both sides name the same commit.

That published commit exists only when the recorded sha is missing: it is the copied tree committed in
`~builder/nixflakes-scratch` and pushed into the checkout as `refs/tags/provisioned-snapshot`, with the
directory removed afterwards.  Objects arrive; no branch, no
`HEAD`, no file in the checkout changes.  The sha is invented inside the guest whenever the deploy's own
commit was not pushed, so `deployed` and the git host can disagree about it until the operator pushes the
real commit — which is why `deployed` is only moved once the switch succeeded: a failed switch leaves it
naming what the guest still runs.

`DEPLOYED.md` in the checkout is how the agent learns what happened.  This unit's journal belongs to root
on `ai`, and the guest's own journal dies with the reboot, so the alternative was the agent guessing from
a moved tag.  It names the commit, the tag, the `ai` snapshot, the UTC time, and the commit's subject, and
says plainly that `main` and `HEAD` were left where the agent had them.  It is untracked on purpose:
provisioning has no business committing to the agent's branch.

The switch runs as root while the checkout is owned by `builder`, so it first runs `git config --global
--replace-all safe.directory /home/builder/nixflakes`.  That is scoped to this one repository rather than
`safe.directory '*'`, because a wildcard would make any repository the agent creates in the guest trusted
by root's nix.

Streaming the secrets tree is fatal when it fails, because the switch reads secrets from that directory;
the fetch is not, since a deploy built from an unpushed commit has nothing on the server and the publish
path above covers it.

A switch that fails ends the pass there: `deployed` is not moved, `DEPLOYED.md` is not written, and the
marker keeps naming the snapshot that is actually applied, so the next boot retries.

The switch and the reboot run as **root over ssh** (`provision.activationUser`, default `root`), the
file and git work as `builder`.  `builder` has no sudo in the guest — it is in `wheel` only so
`config/nixos/core/nix` trusts `@wheel` as a nix user, and with no password `sudo` simply fails — so
root is the one privileged path.  Both guests set `PermitRootLogin = "prohibit-password"`, and
`buildvm-install` authorizes the root-owned login keys in `/root/.ssh` on every graft pass.

Its ssh uses the keypair `buildvm-install` generates for root (`provision.loginKey`) and trusts the
guest on first use into `/var/lib/buildvm/guest-known_hosts`, its own file rather than root's
`known_hosts`, and `buildvm-install` deletes that file on every pass where it grafts the guest.
So a reseed re-trusts the guest's new sshd keys automatically, while a key that changes under a
running guest still fails as a real warning.

Everyone else pins into their own `~/.ssh/known_hosts`: Hermes' shell backend
(`tools/environments/ssh.py`, `StrictHostKeyChecking=accept-new`, no `UserKnownHostsFile` of its
own), `deploy-ai` running as root, and your interactive `ssh`.  A graft pass therefore also removes
the `[127.0.0.1]:<sshPort>` entry from each login key owner's home (resolved with `getent passwd`)
plus `/root/.ssh/known_hosts`, and chowns the result back to its owner.  Only that entry goes: a
consumer's other pins, the git host on 2223 for instance, are not the guest's business.  Nothing
else rewrites those files, so an entry left by an older guest is cleared by the next graft pass;
to do it by hand, `ssh-keygen -R '[127.0.0.1]:2224' -f ~/.ssh/known_hosts`.
So on a fresh disk the first boot ends with
the guest running `platforms/buildvm.nix`: Xfce and Xvnc, nix gc, deploy-rs, and a root filesystem
grown to fill the partition.  Growing it takes both halves: `boot.growPartition` enlarges the
partition, and `autoResize = true` on the root filesystem is what puts `x-systemd.growfs` in the fstab
so `systemd-growfs-root.service` runs `resize2fs` into it.  Either one alone leaves ext4 at the
image's few GiB.

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
# `deployer` accepts the build VM's public key, and the private half is `0600` root (§4), so name it.
sudo ssh -i /run/agenix/ai_buildvm_id_ed25519 -p 22 deployer@127.0.0.1 'deploy-ai --status'   # what the agent runs from inside the guest
sudo ssh -i /run/agenix/ai_buildvm_id_ed25519 -p 22 deployer@127.0.0.1 'ls /'                 # must print the gate refusal, exit 1
sudo deploy-ai --repo ssh://builder@127.0.0.1:2224/home/builder/nixflakes --ref main --dry-run
```

`deployer`'s login shell *is* the gate, so sshd invokes it as `-c "<your command>"` and exports the
same string as `SSH_ORIGINAL_COMMAND`.  The gate (`pkgs/deploy-ai/gate.nix`) reads the command from
either, splits it on whitespace, and `exec`s `/run/wrappers/bin/sudo -n /run/current-system/sw/bin/deploy-ai`
with those arguments.  That sudo is the setuid copy, named by the module rather than resolved from a
PATH: `modules/nixos/deploy-ai/default.nix` builds the gate with
`pkgs.deploy-ai.gateFor "${config.security.wrapperDir}/sudo"`, because sshd's PATH resolves a bare
`sudo` to the read-only store copy, which has no setuid bit, and sudo then refuses every command.  The
module asserts `config.security.sudo.enable`, since that option is what puts the setuid copy in the
wrapper directory.  `pkgs/deploy-ai/gate.nix` never reads `$1`: a gate that does refuses every command,
including valid ones, which looks like an ssh failure from the guest's side.  `nix build
'.#packages.x86_64-linux.deploy-ai.passthru.tests.gate'` pins both wirings and the refusals.

`--status` prints one labelled row per question and nothing else: the commit and toplevel ai runs,
whether the units named in `/etc/deploy-ai/health-units` are active and the endpoint in
`/etc/deploy-ai/health-url` answers 2xx or 3xx (a 404 is reported as a status code, a dead listener
as `answered nothing`, and an unset endpoint as `no health endpoint configured` — the three used to
collapse into one `api`), any pending rollback, what the VM was last told
(and an explicit `ssh to the VM failed` rather than a misleading `none` when the key is wrong), whether
the baseline snapshot exists, that the policy is locked, the allowlist, the last line of the deploy log,
and whether the reboot guard is still armed.  Both files come from `nixflakes.deploy-ai.healthUnits`
and `nixflakes.deploy-ai.healthUrl`, which is where they belong: a health check describes the host,
and `platforms/ai.nix` sets the endpoint from the gateway's own port setting.  The package once
hardcoded `http://127.0.0.1:8642/api/v1/health`, a path the gateway has never served (it answers
`GET /health` and `GET /health/detailed`, `hermes-agent/gateway/platforms/api_server.py:1555`), so
`--status` called a healthy api `down` and no submit could switch.  Moving the endpoint into config
means the next time a port or path changes, the fix is an edit to `platforms/ai.nix` — an allowlisted
path an agent can submit — instead of a denylisted one only an operator can apply.  `/etc/deploy-ai/deployed-source` holds the store path of the source
the running system was built from (`nixflakes.deploy-ai.deployedSource`, kept alive by
`system.extraDependencies`), `/etc/deploy-ai/deployed-commit` holds the flake rev the running
system came from (`-dirty` suffix if you switched from a dirty tree — the gate strips it, and the
content diff still catches the uncommitted part). A real deploy is the dry run without `--dry-run`;
do the first one yourself so you watch: mirror fetch → ancestor check → content diff against the
deployed source (refuses anything outside `nixflakes.deploy-ai.allowlist`) → build on `ai`, capped by
`nixflakes.deploy-ai.buildMaxJobs` and with `private` overridden to
`nixflakes.deploy-ai.privateInput` → health probe of the *current* system →
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

### Applying a change the agent made in the guest

The agent edits and commits in `/home/builder/nixflakes`; it does **not** switch the guest.  `builder`
has no sudo, and the key in its `~/.ssh` is not in the guest's `/root/.ssh/authorized_keys` (§4), so
there is no route from the agent to guest root.  Activation goes through the gate on `ai`, which is
the only place holding a root-authorized key:

```bash
git add -A && git commit -m 'guest: …'      # as builder, in /home/builder/nixflakes
```

Then on `ai`, the agent's own account reaches the deployer (`§7`), whose gate runs `deploy-ai` as root
through the setuid sudo:

```bash
ssh -i /run/agenix/ai_buildvm_id_ed25519 deployer@127.0.0.1 'deploy-ai --repo ssh://builder@127.0.0.1:2224/home/builder/nixflakes --ref main --dry-run'
ssh -i /run/agenix/ai_buildvm_id_ed25519 deployer@127.0.0.1 'deploy-ai --repo ssh://builder@127.0.0.1:2224/home/builder/nixflakes --ref main'
```

The string starts with `deploy-ai`, not `sudo deploy-ai`: the gate accepts only a `deploy-ai` invocation
and does the privileged step itself, so a `sudo` prefix is refused (§7).  That key is `0600` root (§4), so
both lines run as root.

That route needs the commit to be reachable from a repository root can read.  The commit in the
guest's own checkout is, because the guest *is* that repository — and the shorter route is a patch
straight from the guest to the gate, which needs no push at all (§5).

`deploy-ai` mirrors that repo, refuses anything outside `nixflakes.deploy-ai.allowlist` or outside the
deployed commit's history, builds `nixosConfigurations.ai` on `ai` itself from a git-free copy of the
tree, and switches `ai`.  Switching `ai` re-runs `buildvm-provision`, which builds the
same tree inside the guest and moves tag `deployed` to it without touching the agent's checkout (§6) — so
the guest converges on what `ai` runs, while the agent's `main` stays where it left it.  The guest is a
copy of `ai`'s system: a change only the guest needs still arrives through `ai`, and the VM takes it
when provisioning rebuilds.

Two consequences worth knowing:

* Nothing schedules this.  There is no timer: `buildvm-provision` runs once at boot, and again when a
  switch of `ai` restarts the unit, which happens whenever the switch changes what it is configured with
  — the tree it provisions, the commit it records, or the image.  A switch that changes none of those
  leaves the guest on its current system until the next boot, so a deploy can be minutes late to the VM
  or wait for a reboot, and `journalctl -u buildvm-provision -b` is the only record of when it ran.
* Nothing in the guest's checkout moves on a deploy: no reset of `main`, no stash, no lost commits.  If
  the agent wants its work to ride on the deploy, it rebases onto `deployed`, which `DEPLOYED.md` tells
  it to do (§6).

## 9. Reset or shrink the guest

```bash
sudo systemctl stop buildvm
sudo wipefs -a /dev/disk/by-partlabel/buildvm
sudo systemctl restart buildvm-install buildvm     # throws away everything the agent built
```

`wipefs` clears the image's GPT signature, which is what makes the installer write the seed again.
The installer also drops `/var/lib/buildvm/guest-known_hosts`, and the guest's entry from every
consumer's `~/.ssh/known_hosts` (§7), on every pass where it grafts the guest, because a new image
carries new sshd host keys.  The guest grows its own partition and
filesystem on boot (`boot.growPartition` plus `autoResize`), so nothing needs resizing.  If a guest
reports a filesystem far smaller than its partition, the fstab entry is missing `x-systemd.growfs`:
`sudo ssh -p 2224 root@127.0.0.1 'findmnt -n -o OPTIONS /; df -h /'` and grow it once with
`resize2fs /dev/disk/by-label/buildvm`.  Leave
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
it keeps working only if you keep `deployedSource`).  Every `deploy-ai` build runs on a VM, so without
`buildvm` there is nothing left to deploy with — rebuild ai with `nixos-rebuild switch` on the host.
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
| `buildvm-provision: provision.sourcePath is unset, so there is nothing to put in the guest` | `ai` was not built from a git snapshot, so `deployedSource` (§6) is empty.  Provisioning has nothing to put in the guest |
| `buildvm-provision: could not copy the tree ai runs on into the guest's store` | the `nix copy` of `provision.sourcePath` (and the `private` source) into the guest failed — guest down, ssh refused, disk full, or the guest's store unwritable.  Provisioning stops rather than switching a half-copied tree, and stops the same way when `/home/builder/secrets` cannot be filled, because the switch reads secrets from there (§6); `sudo systemctl restart buildvm-provision` re-copies |
| `buildvm-provision: cannot hand /home/builder/nixflakes to builder`, or `/home/builder/nixflakes/.git: Permission denied` followed by `cannot init` | the path exists but belongs to root — generations before provisioning ran created the checkouts while mounting the image, and sshd logs you in as `builder`, which cannot write there.  Provisioning now hands those directories over as root before copying into them, so this row applies to generations before that fix or to a guest where root's authorized key is missing (`sudo ssh -p 2224 root@127.0.0.1 'ls -ld /home/builder/nixflakes'`) |
| `chown: invalid group: 'builder:builder'` inside `cannot hand …` | generations that asked for a group named after the user.  The guest's build user has no such group (NixOS puts `isNormalUser` in `users`), so provisioning now chowns the owner alone |
| `git add` / `error: unable to write file …: Permission denied` while seeding a checkout, or `buildvm-provision: could not copy … into /home/builder/secrets` | the Nix store is read-only (0444 files, 0555 directories) and a store copy keeps those modes, so a copy out of the store arrives unwritable.  Provisioning runs `chmod -R u+w` on every copy it makes in the guest, so this means that chmod itself failed: the directory is not `builder`'s (the `cannot hand` row above) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED`, `Offending … key in /root/.ssh/known_hosts:N`, `Host key for [127.0.0.1]:2224 has changed` — from provisioning, from Hermes' shell, from `deploy-ai`, or from your own `ssh` | an old fingerprint is pinned while the guest's sshd keys are new.  A graft pass clears `/var/lib/buildvm/guest-known_hosts` and the `[127.0.0.1]:2224` entry out of every login key owner's `~/.ssh/known_hosts` (§7), so this row applies to generations before those fixes, to a graft pass that found no user to graft (`skipping grafting` in `journalctl -u buildvm-install`), and to a consumer whose home `getent passwd` cannot resolve: `sudo rm -f /var/lib/buildvm/guest-known_hosts` or `ssh-keygen -R '[127.0.0.1]:2224' -f ~/.ssh/known_hosts` |
| `buildvm-provision` waits forever, then `start operation timed out`, while `journalctl -u buildvm` shows `BdsDxe: No bootable option or device was found` | the guest is not running an OS, so nothing listens on 2224 and qemu's user-mode networking accepts your connection and resets it, which ssh reports as `kex_exchange_identification: read: Connection reset by peer` rather than "connection refused".  Usually `buildvm-install` never ran this boot, so the disk was never written: `sudo systemctl stop buildvm && sudo systemctl start buildvm-install && sudo systemctl start buildvm`.  If it is in a failed state from an earlier attempt, `sudo systemctl reset-failed buildvm-install` first, and check `journalctl -b -u buildvm-install` for why it stopped early. |
| `buildvm-provision: guest ssh never came up on port 2224` | the guest is not booting (see the qemu rows) or `~builder/.ssh/authorized_keys` was never grafted |
| `nc -z 127.0.0.1 2224` says OPEN and `ssh -vv` prints `Connection established` then `Local version string …` and waits forever, with no banner and no `Permission denied`, even for `root` with a key the log says was grafted | qemu's user-mode network accepts the forward on `ai` and then cannot reach the guest, so the guest has no address on the pinned subnet. `journalctl -u buildvm -b` showing `[ OK ] Started SSH Daemon.` rules out sshd, and `ip a` inside the guest showing the card `state DOWN` with no address confirms it. Two ways that happens: `networking.useNetworkd = false` with `networking.useDHCP = false` leaves `systemd.network.networks` as `{ }`, so nothing manages the interface; or a unit matched on an interface name the guest no longer uses (`ens3` on one generation, `enp0s3` on the next). Check `nix eval '.#nixosConfigurations.buildvm.config.systemd.network.networks'` — it should show the `40-buildvm-nat` unit with `matchConfig.MACAddress` (§2) |
| `buildvm-provision: seeded /home/builder/nixflakes from the tree ai runs on` | informational, and only on a checkout with no commits: the tree `ai` runs is committed there so the switch has something to name (§6).  Provisioning never writes into a checkout that already has history |
| `buildvm-provision: could not fetch from ssh://…; the guest keeps whatever commits it already had` | the guest could not reach `provision.origin` with the key `buildvm-install` grafts into `~builder/.ssh`: the deploy key for `nixflakes.git` is not registered (§2), or the guest has no route out.  Check from inside the guest: `ssh -p 2224 builder@127.0.0.1 'ip route; getent hosts git.pleunetowne.com'` must show `default via 10.0.2.2 dev <interface>` and resolve, otherwise `buildvm.service` is not passing the pinned `-netdev user,…,net=…,host=…,dns=…` arguments or the guest config no longer carries the MAC-matched network unit (§2).  The unit matches by MAC, so the interface name is whatever predictable naming gives this boot (`ens3`, `enp0s3`, …) and is not itself the thing to check.  Not fatal: an unpushed deploy is published from the tree `ai` runs (§6) |
| `buildvm-provision: could not point /home/builder/nixflakes at ssh://…` | `git remote add`/`set-url` failed, which needs the checkout to be writable (§the permission row above) |
| `buildvm-provision: <sha> is not in the guest's repository; recording the published tree` | informational: that commit is not pushed to `origin`, so the guest records the commit provisioning published from the tree `ai` handed it (§6).  The sha the guest tags is not the sha `ai` recorded until the deploy is pushed.  `sudo ssh -p 2224 builder@127.0.0.1 'git -C /home/builder/nixflakes log --oneline -3 && git -C /home/builder/nixflakes tag -l'` shows what is there |
| `buildvm-provision: could not tag <sha> as deployed` | reached only after the switch succeeded: the checkout is not writable or is in a state git will not accept; `sudo ssh -p 2224 builder@127.0.0.1 'git -C /home/builder/nixflakes status --short'`.  The guest runs the new system with a stale `deployed`, so fix it and re-run |
| `buildvm-provision: could not push the deployed tag to ssh://…; the tag in /home/builder/nixflakes still names what the guest runs` | the guest switched and tagged locally but `origin` refused the tag: no deploy key (§2), or the host rejects force-pushing a tag it does not own.  The guest's own tag still names what it runs, and the operator can push the real commit instead |
| `buildvm-provision: deployed is <sha>; /home/builder/nixflakes, its main and its working tree were left alone` | success: the tag moved and nothing in the checkout changed (§6).  The agent reads `DEPLOYED.md`, and rebases onto `deployed` when it wants its own commits on top of the deploy |
| `buildvm-provision: could not write /home/builder/nixflakes/DEPLOYED.md` | the switch succeeded and the guest runs the commit, but the note the agent reads did not land: `/home/builder/nixflakes` is not writable, or the ssh session dropped.  A warning, not a failure, and the marker is written after it, so the unit will not repeat the pass for this snapshot: `sudo ssh -p 2224 builder@127.0.0.1 'git -C /home/builder/nixflakes log -1 deployed'` says the same thing, and the next deploy writes the file again |
| `buildvm-provision: could not seed /home/builder/nixflakes from the tree ai runs on` | fatal, and only on a checkout with no commits: the copy worked but the seed commit failed, usually an unwritable checkout (the permission row above) |
| `buildvm-provision: could not record the copied tree as a commit in /home/builder/nixflakes` | fatal, and only when the deploy's sha is missing from the checkout: the copied tree could not be committed in `~builder/nixflakes-stream` or pushed as `refs/tags/provisioned-snapshot`, so there is nothing to put in `deployed-commit` (§6).  The switch itself is unaffected by this — records are the only thing it blocks |
| `error: getting status of "/nix/store/…-nixflakes-source": No such file or directory` from the guest switch | the copy into the guest's store did not happen, or that path has since been collected there (§6).  Check `nix eval '.#nixosConfigurations.ai.config.systemd.services.buildvm-provision.script'` for the `--flake` argument and `sudo ssh -p 2224 root@127.0.0.1 'ls -d /nix/store/*-nixflakes-source'` in the guest |
| `buildvm-provision: guest running its own config at <snapshot>` | success: the guest switched and is rebooting into it, and `buildvm-provision` will not run again for this snapshot (§6) |
| `buildvm-provision: guest already at <snapshot>` | informational, on every boot after a successful pass: `/home/builder/provisioned-commit` names the snapshot `ai` runs, so nothing is copied and nothing is rebuilt (§6).  A deploy changes that store name, which is what makes the next pass do the work |
| the guest switched but the agent's `main` still has its own commits | expected: provisioning never moves `main` (§6).  `git rebase deployed` is the agent's job and `DEPLOYED.md` says so; the agent's uncommitted work is untouched for the same reason |
| `error: write of <N> bytes: No space left on device` partway through the guest switch | the guest's root filesystem is smaller than its partition, so the closure has nowhere to go: compare `df -h /` with `lsblk` and grow it once (`resize2fs /dev/disk/by-label/buildvm` as root in the guest).  A switch cannot fix this itself — the filesystem grows at boot, and the switch's own build needs the room |
| `buildvm-provision: switch failed; guest left as it is` | read the `nixos-rebuild` output in `journalctl -u buildvm-provision -b`; the guest keeps the system it had, `deployed` is not moved, and nothing in the checkout was touched — the marker is not written either, so the next deploy retries |
| `buildvm-provision: guest did not come back after the switch` | the new system does not boot — the switch rewrote the ESP entries. Boot the previous loader entry from the guest's serial console (`journalctl -u buildvm -b`), or reseed (§9) |
| `journalctl -b -u switch-to-configuration`: `[agenix] decrypting …` then `chmod: cannot access '/run/agenix.d/N/<name>.tmp': No such file or directory`, `mv: cannot stat …`, `Activation script snippet 'agenixInstall' failed (1)` | no identity in `config.age.identityPaths` could open the file, i.e. the secret is encrypted for a different key. Nothing else reports this, and the activation errors are not fatal, so the switch finishes with an empty `/run/agenix`. Re-encrypt for `ssh -p … 'cat /etc/ssh/ssh_host_ed25519_key.pub'` (§4) |
| the guest stays the seed image (no Xfce, no activated config) | provisioning never ran or failed: `systemctl status buildvm-provision`; its `ConditionPathExists` means `provision.loginKey` must exist, which `buildvm-install` generates — `ls -l /var/lib/buildvm/keys/provision` |
| `buildvm-provision`: `Permission denied (publickey)` from the switch, while the builder-side checks work | the guest's `/root/.ssh/authorized_keys` has no root-owned key, i.e. the running guest predates the root graft or `buildvm-install` never ran after it: `sudo ssh -p 2224 root@127.0.0.1 true`, then `sudo systemctl restart buildvm-install`.  `builder` cannot do this work — it has no sudo, by design |
| `buildvm-provision-start[…]: nix: command not found`, right before `could not copy the tree ai runs on into the guest's store` | The copy is a `nix copy` run by this unit on `ai`, and a unit's PATH is only what its `path` lists — `pkgs.nix` belongs there.  A unit built before that belongs is fatal at the copy step in exactly these two lines; re-apply `ai` (§9) |
| `deploy-ai: command not found` inside the guest, or a `deploy` binary that looks like a rewrite of it | Nothing regressed. `deploy-ai` runs on `ai` and reaches it through the `deployer` gate over ssh; the guest has no copy on purpose, and nothing builds for `ai` inside the guest — provisioning builds only the guest's own configuration, from ai's source. The `deploy` in the guest's PATH is `deploy-rs` (`platforms/buildvm.nix`), unrelated and with no target for `ai`. `builder` also has no sudo, by design (§4 of `platforms/buildvm.nix`) |
| Hermes terminal: `Load key "…": Permission denied`, then `Permission denied (publickey)` | the unit's own key is missing or unreadable — Hermes uses `/var/lib/buildvm/keys/hermes/id_ed25519`, which `buildvm-install` creates, so `ls -l /var/lib/buildvm/keys/hermes` and `systemctl status buildvm-install` first.  `Permission denied (publickey)` with a readable key means the guest does not authorize it: the pass that generated it did not graft (`journalctl -u buildvm-install -b`) |
| ssh says `Permissions … for '<key>' are too open` / `This private key will be ignored` | ssh refuses a private key that someone other than its owner can read.  `buildvm-install` writes every key it generates `0600` to its own `owner` and the agenix secret `0600 root`, so this means something rewrote them, or a unit is pointed at a key it does not own: `ls -l <key>` and `sudo chmod 600 <key>`, or give that consumer its own `loginKeys` entry |
| qemu: `pflash: file … does not exist` | `/var/lib/buildvm/efi-vars.fd` was deleted and `buildvm.service` started before `buildvm-install.service` seeded it — `systemctl start buildvm-install` |
| guest drops to the UEFI shell / `Boot Failed` | no NVRAM entry and no ESP fallback path; the fallback needs `EFI/BOOT/BOOTX64.EFI` on the ESP, so re-run the bootloader phase in the guest (`nixos-rebuild switch --bootloader-only`) or reset `/var/lib/buildvm/efi-vars.fd` |
| qemu starts, ssh times out | no `/dev/kvm` (`ls -l /dev/kvm`), or no loader on the ESP — read `journalctl -u buildvm -b`, which shows the guest's serial console |
| guest sits in Emergency Mode | root is named by the ext4 label `buildvm`; a stale filesystem or a label from another image leaves `/dev/disk/by-label/buildvm` unresolvable |
| a guest build *you* run fails on the `secrets` input | it fetched the input over ssh: §2 (deploy key) plus `known_hosts` for port 2223. Provisioning avoids this with `--override-input private` (§6) |
| gate refuses `outside the deploy-ai allowlist` | correct; the refusal names the nearest allowed prefix — widen `nixflakes.deploy-ai.allowlist` only deliberately |
| `deploy-ai gate: only 'deploy-ai ...' is accepted here.` for a command that looks correct | sshd hands the gate your command as one string, so quote it once (`ssh deployer@127.0.0.1 'deploy-ai --status'`) and put nothing else in it.  If *every* command is refused, the running gate is a generation that read `$1` instead of `SSH_ORIGINAL_COMMAND`/`$2`; rebuild from `pkgs/deploy-ai/gate.nix` and check with `nix build '.#packages.x86_64-linux.deploy-ai.passthru.tests.gate'` |
| `deploy-ai gate: refusing a command containing '<char>'.` | `;`, `&`, `\|`, `<`, `>`, `$`, a backtick and `*` cannot reach `deploy-ai` intact; send one command per ssh and keep those characters out of arguments.  The gate never re-evaluates the string, so this is a guardrail against `deploy-ai`'s own parser, not a sandbox |
| `deploy-ai: refusing: the patch changes the deployment policy (allowlist, keys, users, sudoers); the operator must apply that out-of-band` | the submitted tree evaluates to a different `nixflakes.deploy-ai.policyDigest` than `/etc/deploy-ai/policy-digest`, so the patch moves one of the settings the gate enforces against it — the allowlist, a key, a user, a sudo rule, nix's `trusted-users`, a buildvm path (§5).  Nothing was built or applied.  `deploy-ai --vet` reproduces the refusal without a submission, and the change is the operator's to deploy by hand (§5) |
| gate refuses `does not have the deployed commit … in its history` | ref rebased or unrelated; rebase onto the deployed commit |
| `sudo: /nix/store/…-sudo-1.9.17p2/bin/sudo must be owned by uid 0 and have the setuid bit set` on every `deploy-ai` command | sshd's `exec` PATH resolves `sudo` to the read-only store copy, which has no setuid bit; NixOS grants it only through `security.wrapperDir` (`/run/wrappers/bin/sudo`).  The gate execs that path by name, and `modules/nixos/deploy-ai/default.nix` asserts `security.sudo.enable` so the copy exists, which means this message comes from a generation whose gate predates `pkgs/deploy-ai/gate.nix`'s `sudoPath` (§7) |
| `deploy-ai gate: /run/wrappers/bin/sudo is not executable, so nothing can be deployed.`, followed by `deploy-ai gate: ai needs security.sudo.enable for the setuid copy of sudo to exist.` | the setuid copy the gate names is missing, which means `security.sudo.enable` is off on the running system.  `modules/nixos/deploy-ai/default.nix` asserts that option, so expect this pair from a generation whose gate was built before that wiring, and check `nix eval --accept-flake-config '.#nixosConfigurations.ai.config.security.wrapperDir'` if `ai` sets it somewhere other than `/run/wrappers/bin`.  The gate refuses with those two lines rather than letting sudo fail with the store-path message in the row above (§7) |
| a reboot you did not ask for | the 60-minute guard armed before a switch; `systemctl cancel --when` |
| state to inspect | `/var/lib/deploy-ai/{toplevel,commit,refs.log,lock,rollback-pending,rollback-previous,log/build.log}` |
