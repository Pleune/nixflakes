# Letting the Hermes agent edit this flake and deploy `ai`

The agent on `ai` used to run in a Docker sandbox on the same box, so it could reach this flake and
`nixos-rebuild` as root. Execution now lives in a VM, and the only route back is one auditable gate.

## Three pieces

| Piece | Where | Role |
| --- | --- | --- |
| `buildvm` | `platforms/buildvm.nix`, `nixosConfigurations.buildvm` | NixOS guest the agent's shell runs in. No bootloader: `make-disk-image.nix` emits a raw ext4 filesystem image, and qemu boots it with `-kernel`/`-initrd`/`init=` from the guest's own toplevel. |
| `nixflakes.virtualisation.buildvm` | `modules/nixos/virtualisation/buildvm/` | On `ai`: one-shot `buildvm-install` seeding the raw partition, then a `buildvm` unit running qemu/KVM with `hostfwd=tcp:127.0.0.1:2224-:22`. |
| `deploy-ai` | `pkgs/deploy-ai/`, `modules/nixos/deploy-ai/` | The only way anything changes `ai`'s system: scope check → build in the guest → copy the closure → health probe → switch → auto-rollback. |

Shared constants (guest user, ssh port, disk, work directory, origin URL, the guest's public key) are
written literally in the platform file that needs them: `platforms/ai.nix` for the host side,
`platforms/buildvm.nix` for the guest, `platforms/buildvm-bootstrap.nix` for the seed image.  There is
no shared constants module, so a value that has to agree on both sides is duplicated and edited by hand —
which is the point: the files sit next to each other, and only the values that must agree are repeated.

## Nothing about the system lives in the guest

There is **no repository on `ai`** and no host state in the VM. What is deployed is recorded on the
host only: `environment.etc."deploy-ai/deployed-source"` is the flake source the running system was
built from (pinned by `system.extraDependencies` so GC cannot collect it) and
`environment.etc."deploy-ai/deployed-commit"` is its revision. The VM's one channel to that fact is
`/home/builder/deployed-commit`, written by the gate after a successful switch.

Because the baseline is a store path and not a git ref, scope checking compares **file contents**:
history can be rewritten without hiding a protected file.

## Dataflow

```
agent in the guest
  ├─ terminal backend ssh ──────────────► builder@127.0.0.1:2224 (the guest)
  ├─ git clone/push ssh://git@git.pleunetowne.com:2223/…/nixflakes.git
  └─ ssh deployer@ai 'deploy-ai --repo <url> --ref <rev>'
        └─ login shell accepts nothing else ─► sudo -n deploy-ai
             ├─ mirror <url> into /var/lib/deploy-ai/repo (root-side bare mirror)
             ├─ deployed commit must be an ancestor of <rev>
             ├─ diff candidate tree against /etc/deploy-ai/deployed-source,
             │  every differing path must match /etc/deploy-ai/allowlist
             ├─ git archive <rev> | tar → /home/builder/deploy-candidate
             ├─ nix build …#nixosConfigurations.ai… in the guest
             ├─ nix-copy-closure --from builder@127.0.0.1 -p 2224
             ├─ health: hermes-agent/backend/webui active, 8642 answering, VM reachable
             ├─ systemctl reboot --when=+60m  (guard, armed just before the switch)
             ├─ switch-to-configuration switch
             ├─ unhealthy → switch back to the previous toplevel
             ├─ cancel the guard
             └─ write <sha> to /home/builder/deployed-commit
```

`--repo` is any git URL root can read: the git host, or the guest's own checkout
(`ssh://builder@127.0.0.1:2224/home/builder/nixflakes`). Fetches use the build VM key
(`nixflakes.deploy-ai.buildKey`), whose path is published in `/etc/deploy-ai/build-key` while the key
itself stays root-owned. `--local` builds on `ai` instead of the guest.

## Bring-up and daily use

Operator steps: `docs/buildvm-ai-setup.md` (disk, keys, switch, checks, reset, Docker rollback).
Agent-side commands: `skills/deploy-ai/SKILL.md`. `--dry-run` builds and probes without switching;
`--list` prints a repository's refs and the deployed commit; `--status` prints the deployed toplevel,
baseline, pending rollback and allowlist. Pushing alone changes nothing on `ai`.

## Deliberate limits

- `builder` is not in `wheel`, so a root shell in the sandbox is not obtainable.
- The `deployer` login shell runs exactly `sudo -n deploy-ai …`, and sudoers lists only that command.
  That is a guardrail against mistakes, not a sandbox: whatever the gate can reach is the agent's
  real ceiling.
- The allowlist lives in `platforms/ai.nix` (`nixflakes.deploy-ai.allowlist`) →
  `/etc/deploy-ai/allowlist`, and is enforced before anything is built. `platforms/` is only reachable
  through `platforms/ai.nix` and `platforms/buildvm.nix`, so another machine's config is out of reach.
- Ancestor check plus content diff: neither a force-push nor a rebased branch smuggles a protected
  path past the gate.
- The reboot guard is armed immediately before the switch and cancelled only after health passes, so
  a build that fails after an hour leaves no reboot pending.
- Not covered: a config that breaks `nixos-rebuild` itself, or a self-referential redefinition of the
  gate. Those need the console.
- Secrets stay root-owned on `ai`. The guest reads the private `secrets` input through its own deploy
  key; nothing in the repo carries agenix material and the gate never copies host secrets into the
  guest.
