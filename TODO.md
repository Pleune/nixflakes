# Hermes agent self-deploy on `ai`

Implemented and evaluated here; the disk work and first switch happen on `ai` (§Open). Design:
`docs/hermes-agent-flake-deploy.md`. Operator steps: `docs/buildvm-ai-setup.md`. Agent instructions:
`skills/deploy-ai/SKILL.md`.

## Decisions

Raw partition passthrough (no qcow2, no virter). Docker retired on `ai`; the bot desktop follows the
sandbox (`bot_desktop.placement = "auto"`). Gated switch with allowlist + automatic rollback. **No
repository on `ai`**: the gate is told per call which repo to read, mirrors it root-side into
`/var/lib/deploy-ai/repo), and records what is deployed only on the host
(`environment.etc."deploy-ai/deployed-source"` + `deployed-commit`, pinned via
`system.extraDependencies`). The VM learns the live commit only from `/home/builder/deployed-commit`.

## Files

- `lib/buildvm/default.nix` — shared constants; `publicKey` is still a placeholder.
- `platforms/buildvm.nix` — guest system: `builder` (no wheel), sshd, Xfce/tigervnc set, nix GC,
  `nixflakes.buildvm.diskImage` from `make-disk-image.nix`.
- `modules/nixos/virtualisation/buildvm/default.nix` — `buildvm-install` + qemu/KVM units on `ai`.
- `pkgs/deploy-ai/{deploy-ai.sh,default.nix,test-scope.sh}` — the gate, its package
  (`passthru.tests.scope`), and an unprivileged guard test.
- `modules/nixos/deploy-ai/default.nix` — `deployer` account whose login shell is `deploy-ai-gate`
  (`shellPath` set so NixOS resolves it), sudoers limited to that one command,
  `/etc/deploy-ai/{allowlist,deployed-commit,build-key}`, state tmpfiles, `deploy-ai-boot-rollback`.
- `platforms/ai.nix` — docker block deleted; buildvm + deploy-ai enabled; Hermes
  `terminal.backend = "ssh"`, `bot_desktop.placement = "auto"`, `approvals.deny` for disk/reboot commands.
- `flake.nix` — `nixflakesSource` (`builtins.path`, filtering `.git`, `.direnv`, `.ralph`, `result`,
  `state.json`, `secrets`) as `deployedSource`, `deployedCommit = self.rev or self.dirtyRev`, the
  `buildvm` system and its `buildvmBoot` paths. README pointer.

## Validation

```
nix eval --option eval-cache false .#nixosConfigurations.ai.config.system.build.toplevel.drvPath
nix eval --option eval-cache false .#nixosConfigurations.buildvm.config.system.build.toplevel.drvPath
nix build --option eval-cache false --no-link .#packages.x86_64-linux.deploy-ai{,.passthru.tests.scope}
bash pkgs/deploy-ai/test-scope.sh      # 8 checks, all pass
bash -n pkgs/deploy-ai/deploy-ai.sh
```

All green as of the last run (ai `wd8yccj6rvp6ccwskg9yccykk1zihkrs`-…drv, buildvm
`ya8bl8q3b7haqilqlwpz0i2534d94vsw`-…drv, scope `v0ssk4ammijax7hj8yi7vwl9k68pdxz7`-…drv). The guest image
built earlier at `/nix/store/cpcsfgmpr7qd67r9naf6w16iwwzybsrj-buildvm-disk` (`nixos.img`, 20 GiB
sparse); re-evaluate after any `buildvm` change. `nix flake check --no-build` cannot pass in this jail:
it fails fetching the private `secrets` input (`age.secrets."PT-Git.crt".file` in `platforms/git.nix`),
unrelated to this work.

## Open

1. Replace the placeholder `publicKey` in `lib/buildvm/default.nix` with the key printed by runbook §4.
2. Authorize that key as a **read** deploy key for `nixflakes.git` and the private `secrets` repo — the
   guest needs `secrets` at eval time (`config/nixos/network/networkmanager`). The guest's default
   identity `~builder/.ssh/id_ed25519` covers it; the gate's mirror uses the same key via
   `nixflakes.deploy-ai.buildKey`.
3. Unverified at runtime: guest boot via `-initrd` + `init=<toplevel>/init`, the `nix-copy-closure`
   round trip, and the desktop under `placement = "auto"` (Xfce/tigervnc, software rendering, no GPU).
4. Outside the gate: a config that breaks `nixos-rebuild` itself, or a rewrite of the gate.

Nothing committed; `git status` also carries unrelated staged work.
