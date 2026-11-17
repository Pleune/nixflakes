---
name: deploy-ai
description: Change this flake and deploy the `ai` host from inside the build VM. Use when editing Nix config that must reach ai, when asked to deploy or roll back ai, or when a deploy is refused by the gate.
---

# Deploying `ai` from the build VM

You are `builder` on the `buildvm` guest. You clone, edit and build; you cannot switch `ai`
directly. The only route is `deploy-ai`, over ssh as the `deployer` account.

```bash
git clone ssh://git@git.pleunetowne.com:2223/mitchpleune/nixflakes.git ~/nixflakes
cd ~/nixflakes                            # /home/builder/nixflakes
# edit, commit on a branch
git push origin fix/whatever              # ordinary push; the gate reads whatever ref you name
REPO=ssh://builder@127.0.0.1:2224/home/builder/nixflakes   # your own checkout: cheapest fetch
REF=refs/heads/fix/whatever
ssh -p 22 deployer@ai "deploy-ai --repo $REPO --ref $REF --dry-run"   # build + probe, no switch
ssh -p 22 deployer@ai "deploy-ai --repo $REPO --ref $REF"
```

`--repo` is required on every call that fetches. `--list` shows a repository's refs plus what is
deployed; `deploy-ai --status` (no `--repo`) shows the deployed commit, toplevel, pending rollback and
allowlist.

## What the gate checks

- The deployed commit must be an **ancestor** of your ref, and the candidate tree's **content** must
  differ from `/etc/deploy-ai/deployed-source` (the source that produced the running system) only
  inside `/etc/deploy-ai/allowlist`: `platforms/ai.nix`, `platforms/buildvm.nix`, `lib/`,
  `modules/nixos/`, `config/`, `pkgs/`, `flake.nix`, `skills/`, `docs/`, `README.md`. Other hosts
  under `platforms/`, `overlay.nix`, `hermes-agent/` and the `secrets` input are not yours. Never work
  around a refusal — report it.
- The running system must be healthy; the gate refuses to switch over a broken one.

## What the VM knows about the live system

`/home/builder/deployed-commit` holds the commit `ai` is running, written after a successful switch.
Compare it with `git rev-parse HEAD` before assuming your change is live.

## Validate before deploying

```bash
nix eval --option eval-cache false .#nixosConfigurations.ai.config.system.build.toplevel.drvPath
nix eval --option eval-cache false .#nixosConfigurations.buildvm.config.system.build.toplevel.drvPath
nix build --option eval-cache false --no-link .#packages.x86_64-linux.mitchpi
"$result/bin/pi" -p "hello" </dev/null   # only when mitchpi changed
```

`git add` new files — Nix cannot see untracked paths.

## If a deploy goes wrong

`deploy-ai` switches back to the previous toplevel when the health probe fails, and the reboot guard
armed right before the switch reboots `ai` into the old system if it is unreachable within 60 minutes.
Say what failed and stop; do not retry the same switch. The build log is `/var/lib/deploy-ai/log/build.log`
on `ai` (root-owned; the gate prints its tail on failure).

## Never

- No `nixos-rebuild`, `switch-to-configuration`, `systemctl`, or writes outside `~/nixflakes`.
- No secrets in the repo; `age.secrets` entries live in the private `secrets` input.
- No reading `/var/lib/*` on the host — the guest has no host filesystem at all.
