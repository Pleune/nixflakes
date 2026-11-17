# TODO — let the Hermes agent change this flake and deploy `ai`

## Goal

Give the Hermes agent on `ai` a Nix-capable execution environment, a repo it can push to, and one
hardened `deploy-ai` entrypoint that builds, switches, health-checks, and rolls back — without letting
it widen its own permissions or brick the host it runs on.

## Locked decisions (your answers)

- Deploy authority: **gated tool only**.
- Build environment: **dedicated VM on the big disk**; you will let us **wipe/repartition** that disk
  (1.82 TiB, UUID `9e27c0a6-7a7d-41fe-8e83-0ed124cea728`) and want a **repartition script**.
- VM runner: **hand-rolled qemu/KVM systemd unit**, disk = **raw partition passthrough** (no
  virter, no qcow2 overlay). The guest owns the partition table inside the disk; the host keeps
  no filesystem on it.
- Docker on `ai`: **retired**. `virtualisation.docker.enable` off, `setup-hermes-container-storage.sh`
  and `btrfs-docker-quota.service` retired, the 1.82 TiB disk wiped clean for the VM.
- Bot desktop: **`bot_desktop.placement = "auto"`** — screen, browser and `computer_use` all run
  inside the VM (guest carries Xvnc + Xfce + browser, 8 GiB).
- Agent execution surface: **`terminal.backend = "ssh"`** into the VM.
- Source of truth: **bare repo on `ai`** the agent pushes to.
- Safeguards: **automatic rollback** + **path allowlist** limiting what the agent may edit.
- Plan status: **approved 2026-11-16 — executing**.

## Architecture (one paragraph)

Hermes' gateway keeps running on `ai` (declarative, unchanged) but its terminal backend becomes
`ssh` → a NixOS guest on `ai`. That guest is the agent's shell: Nix, git, a ~1.4 TiB store disk on the
SSD, deploy keys for `nixflakes` + `secrets`. The agent edits a clone, validates with `nix flake check
--no-build`, and pushes `agent/*` to a bare repo on `ai`. Deploying is one command the agent cannot
substitute: an ssh **forced-command** on `ai` (`deployer@ai` → `deploy-ai --ref <sha>`), which checks
the diff against a root-owned allowlist outside the repo, builds on the VM, activates, health-checks,
and rolls back to the recorded generation on failure. The VM is not privileged on `ai`; the gate is.

## Grounding (verified in-repo / upstream Hermes / pinned nixpkgs)

- SSH backend is first-class: `_BUILTIN_BACKENDS = "local, docker, modal, daytona, vercel_sandbox, ssh"`
  (`hermes-agent/tools/terminal_tool_backends.py:52`), `_SSH_KEYS = ssh_host/ssh_user/ssh_port(22)/ssh_key/ssh_persistent(True)`
  (`:56-57`), `_ssh_pre` refuses without host+user (`:362`). Env `TERMINAL_SSH_HOST/USER/PORT/KEY` map to
  those keys (`hermes-agent/hermes_cli/web_routers/tools.py:86-92`, `hermes_cli/config.py:870-885`), so
  `services.hermes-agent.environment` + `settings.terminal.*` both work.
- The SSH client is spawned with `BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10`
  plus ControlMaster mux (`hermes-agent/tools/environments/ssh.py:174-186`) → TOFU host key, so we pin it.
  `ssh` **and** `scp` must be on the gateway's unit PATH (`tools/environments/ssh.py:35-41`).
- Container knobs become inert under ssh: "Container limits (docker, modal, daytona, vercel_sandbox,
  container plugin backends; **not local/ssh**)" (`hermes_cli/config_defaults.py:346-347`). Sizing moves to qemu.
- `terminal.cwd` is rewritten for ssh by `coerce_ssh_remote_cwd` (`tools/terminal_tool_config.py:236`), so the
  current `terminal.cwd = "/workspace"` (container mount) must become a guest path.
- `file_sync.py` syncs only `$remote_home/.hermes` (skills etc.) for ssh/modal/daytona
  (`tools/environments/file_sync.py:1-5`); your repo clone lives purely in the guest — no mirror overhead.
- Desktop placement: `bot_desktop.placement` (`hermes_cli/config_defaults.py:2512-2520`) resolved by
  `tools/bot_desktop/placement.py`, with `_STREAM_BACKENDS = ("docker", "ssh")` (`:32`) and `resolve()` (`:58`).
  See "Sandbox placement" below — this is the one real behavioural trade-off.
- Existing deploy machinery: `.forgejo/workflows/build.yaml` (push→`nix flake check --no-build`→per-host
  builds→`deploy-*` jobs using `DEPLOY_SSH_KEY`/`SSH_KNOWN_HOSTS`; `git-runner1` reboot guard at `:339`) and
  `deploy.nodes` (`flake.nix:219-246`, `sshUser = "root"`, `deploy-rs.lib.x86_64-linux.activate.nixos`,
  `autoRollback`/`magicRollback` per node at `:240-243`). **`ai` is in neither.**
- Flake evaluation needs the `secrets.git` input (`age.secrets."PT-Git.crt".file` in `platforms/git.nix`)
  → the VM needs deploy keys for both repos, and `nix flake check` cannot run inside this jail.
- Gating levers: `approvals.mode`/`timeout`/`cron_mode`/`single_query_mode`/`unattended_mode`,
  `approvals.deny` = fnmatch globs that block **even under `--yolo`/`mode: off`**, `command_allowlist`,
  `approvals.smart_policy`, `denial_breaker_threshold` (`hermes_cli/config_defaults.py:1644-1679`).
  api_server is unattended (`tools/approval_context.py:188`) so keep `unattended_mode = "deny"`.
- Guest image build is declarative: `<nixpkgs>/nixos/lib/make-disk-image.nix` takes
  `format = "qcow2"` (`:173-174`, converted at `:637-643`); qcow2 backing-file + overlay is the qemu norm
  (`nixos/modules/virtualisation/qemu-vm.nix:142-166` shows the backing-image pattern).
- `pkgs.virter` = LINBIT virter 1.5.0, Go, wrapped binary, uses dnsmasq for its net (`pkgs/by-name/vi/virter/package.nix`).
  No NixOS module upstream → we drive it from a systemd unit. **Note:** virter manages *image files*, not raw
  partitions — see Open decision 1.

## Sandbox placement (your question, answered)

Two separate "sandboxes" are involved and only one is the terminal:

1. **Terminal sandbox** = where `terminal`, `execute_code`, background processes and file writes run.
   Today: the `nousresearch/hermes-sandbox:desktop` container on `ai`. With `backend = "ssh"`: the VM.
2. **Bot desktop** = Xvnc/Xfce screen that the bot's **browser** and **computer_use** drive, placed by
   `bot_desktop.placement`:
   - `auto` (default) follows the terminal backend when it can host a stream — `docker` **and** `ssh` are
     both in `_STREAM_BACKENDS`, so with the ssh backend the screen lands **inside the VM**. Backends that
     cannot host one (modal/daytona/vercel) resolve to `refused` rather than leaking onto the host
     (`tools/bot_desktop/placement.py:22-32`).
   - `gateway` runs the screen on `ai` **outside** the VM — deliberate opt-in, described in the docstring as
     "the boundary-crossing shape": the agent then drives a desktop its own sandbox does not contain.
   - `terminal` forces the VM and errors if it cannot host a screen.

Consequences of `backend = "ssh"` with `auto`: the guest must install the desktop stack (Xvnc + Xfce +
browser) and hold ≥1536 MB free (`bot_desktop.min_free_memory_mb`, `config_defaults.py:2507`) because
"Xvnc + Xfce idle at ~220 MB and a takeover's browser adds 0.5-1 GB"; idle screens stop after
`idle_stop_minutes: 30`. Inside a VM that is software rendering — `ai`'s GPU (`render`/`video` groups on
`users.users.mitch`) is not reachable unless we do vfio passthrough, which is a separate project. So:
- **Keep everything in the VM** (recommended, no boundary crossing): give the guest 8 GiB like
  `container_memory = 8192` does today and install the desktop packages.
- **Or `placement = "gateway"`** if you want the bot's browser/computer_use on the host with real GPU/display,
  accepting that those actions escape the VM boundary while shell stays inside it.

Related fallout under ssh: `container_cpu/container_memory/container_disk/docker_*` in
`services.hermes-agent.settings.terminal` stop doing anything (limits → qemu `-smp`/`-m`), and
`docker_mount_cwd_to_workspace = true` / `docker_network` / `docker_volumes` become dead config. Whether to
retire `virtualisation.docker.enable`, `users.users.hermes.extraGroups = [ "docker" ]`,
`btrfs-docker-quota.service` and `setup-hermes-container-storage.sh` is Open decision 2.

## Open decisions (answer in your approval reply)

1. **Partition vs image.** virter wants a qcow2 *file*; a raw partition is not its model. Options:
   (a) [recommended] dedicated ext4 partition on the big disk holding the guest's qcow2 base + overlay —
   virter-native, snapshot-able, and effectively "the whole partition" for the VM;
   (b) literal whole-partition passthrough (`-drive file=/dev/disk/by-partlabel/…,if=virtio`) with a bespoke
   qemu systemd unit instead of virter;
   (c) virter + qcow2 on a **btrfs** partition, keeping host-side snapshots of the image.
2. **Keep Docker on `ai`?** Hermes won't use it under the ssh backend. (a) [recommended] disable
   `virtualisation.docker.enable` and retire the container-storage script + quota unit, wiping the disk
   clean for the VM; (b) keep Docker enabled for other experiments, data root back on the ext4 root.
3. **Desktop placement** after switching: (a) [recommended] `auto` → screen inside the VM, guest gets the
   desktop stack + 8 GiB; (b) `gateway` → screen/browser/computer_use on `ai` (GPU reachable, boundary crossed).

## Tasks

### 1. Disk: repartition script for the big disk
- [ ] New `setup-buildvm-storage.sh` (sibling of `setup-hermes-container-storage.sh`): refuse unless run on
      `ai`, refuse unless the target disk is the UUID above, print what will be destroyed, require `--force`.
- [ ] Partition layout on the 1.82 TiB disk: `buildvm-img` (~1.5 TiB, ext4 per decision 1a) + optional swap or
      scratch partition; leave a small unallocated tail for later growth.
- [ ] Wipe the old btrfs FS + `/docker` subvolume, drop the docker qgroup limit, and delete
      `btrfs-docker-quota.service` + its mount unit from `platforms/ai.nix` if decision 2a.
- [ ] Persist stable names: `disk/by-partlabel/buildvm-img`, mount unit + fstab entry at
      `/var/lib/buildvm`, `x-systemd.device-timeout` so a missing disk never blocks boot.

### 2. Guest definition (NixOS, virter)
- [ ] `platforms/buildvm.nix`: guest system — Nix (own store on the guest disk), git, openssh, deploy-rs,
      agenix, `nix.gc` + `nix.gc.automatic` with `--max`, a `builder` user, sshd, journald limits, no
      `container.enable` nonsense; desktop packages only if decision 3a.
- [ ] Build the base image declaratively with `make-disk-image.nix` (`format = "qcow2"`) exposed as
      `packages.x86_64-linux.buildvm-image`, so the store contents ship inside the base image.
- [ ] virter config (TOML) generated by Nix: image path (base qcow2 in the nix store), per-host writable
      overlay under `/var/lib/buildvm`, ssh user, network (virter's dnsmasq NAT vs a LAN bridge — decide so
      the guest can reach `git.home.pleunetowne.com` and be reachable from `ai`), CPU/memory (`-smp 12 -m 8192`
      to match today's `container_cpu = 12`, `container_memory = 8192`).
- [ ] `systemd.services.buildvm`: `ExecStart` brings the VM up, `ExecStop`/`ExecStopPost` tears it down
      (`virter virt --down …`), `Restart=on-failure`, `NetworkTimeoutSec`, and confirm virter's exact
      lifecycle/wait flags via `virter virt --help` before writing the unit.
- [ ] KVM: `virtualisation.kvm` (or `/dev/kvm` group access for the service user) and verify
      hardware virtualization is usable on `ai`.
- [ ] Overlay growth guard: `qemu-img info` check + a timer/monitor that alerts before the overlay fills the
      partition; documented resize recipe.
- [ ] Guest state boundaries: the VM is root-owned and isolated from `hermes`; `ai`'s ext4 root keeps only
      qemu/virter state, not the build store.

### 3. Bare repo on `ai` as source of truth
- [ ] New `platforms/` or module config: bare repo `/srv/git/nixflakes.git`, group `deployer`,
      `receive.denyNonFastForwards = true`, `receive.denyDeletes = true`.
- [ ] Agent push key restricted to `refs/heads/agent/*` (forced-command or an access hook); no force-push,
      no `main`, no tags (`skills/commit-style/SKILL.md:70`: `deploy-*` tags belong to the workflow).
- [ ] `main` stays the human branch; a merge from `agent/*` is a human action (or a Forgejo PR the agent opens).
- [ ] Gate reads the ref from the bare repo path (`git+file:///srv/git/nixflakes.git#ai`), never a dirty checkout.

### 4. The gate: `deploy-ai` on `ai`
- [ ] `pkgs/deploy-ai/` derivation installing `/usr/bin/deploy-ai` (repo-local logic; no `update.sh`).
- [ ] Entry: `deploy-ai --ref <sha>` — ref must be reachable from `refs/heads/agent/*` in the bare repo and
      fast-forward from the currently deployed commit; refuse anything else.
- [ ] Allowlist check **before any build**: read root-owned `/etc/deploy-ai/allowlist` (mode 0644, outside the
      repo, not in the agent's write scope) and refuse diffs touching paths outside it. Hard refusals even if
      someone edits the allowlist later: the gate itself, the allowlist, `secrets.git` wiring, ssh/firewall/
      boot config, `services.hermes-agent`, `platforms/buildvm.nix`, disk/mount units.
- [ ] Build offloaded to the VM: `nixos-rebuild build --flake git+file:///srv/git/nixflakes.git#ai
      --build-host ssh://builder@<vm>` (or `nix copy` from the guest) — the closure lands in `ai`'s ext4 store,
      which is unavoidable for activation and is the reason for the store-growth guard.
- [ ] Record `previous_toplevel=$(readlink /nix/var/nix/profiles/system)` before activating.
- [ ] Activate, then health-check: ssh still up, `hermes-agent` + `hermes-backend` + `hermes-webui` units
      active, api_server responding on 8642, docker/guest reachable, and a `systemctl cat` sanity pass.
- [ ] Auto-rollback: run `$previous_toplevel/bin/switch-to-configuration switch` on any failure and report it
      (mirrors deploy-rs `magicRollback`); also `--dry-run` mode that stops after the allowlist + build.
- [ ] Expose it as ssh forced-command for `deployer@ai`:
      `command="/usr/bin/deploy-ai",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty` —
      so the guest's only path onto `ai` is the gate itself.
- [ ] Out-of-band lockout guard, matching the existing `git-runner1` pattern
      (`.forgejo/workflows/build.yaml:339`): `systemctl reboot --when=+1h` style safety during risky deploys.
- [ ] Optionally add `ai` to `deploy.nodes` (`flake.nix:219-246`) with `autoRollback = true` plus
      `build-os-ai`/`deploy-ai` jobs in `.forgejo/workflows/build.yaml`, so the human path and the gated path
      share one definition.

### 5. Hermes wiring (`platforms/ai.nix`)
- [ ] `services.hermes-agent.extraPackages += [ pkgs.openssh ]` — same unit-PATH lesson as the
      `extraPackages = [ pkgs.docker ]` fix already in `platforms/ai.nix:222`.
- [ ] `environment` += `TERMINAL_SSH_HOST` / `TERMINAL_SSH_USER` / `TERMINAL_SSH_PORT` / `TERMINAL_SSH_KEY`
      (or `settings.terminal.ssh_*`), and `settings.terminal.backend = "ssh"`.
- [ ] Replace `settings.terminal.cwd = "/workspace"` with the guest clone path
      (`/home/builder/nixflakes`), remembering `coerce_ssh_remote_cwd` rewrites host-named paths.
- [ ] Drop the now-inert `container_*` / `docker_*` terminal settings (decision 2) and re-place limits on qemu.
- [ ] `settings.bot_desktop.placement` set explicitly per decision 3 (do not leave `auto` ambiguous).
- [ ] Keys via agenix (`age.secrets`), clearing the plaintext TODOs at `platforms/ai.nix:224` and `:395`:
      guest ssh key, git/secrets deploy keys, and a **pinned** known_hosts entry for the guest
      (Hermes uses `StrictHostKeyChecking=accept-new`, i.e. TOFU).
- [ ] `settings.approvals.deny` globs: `nixos-rebuild*`, `deploy-rs*`, `nix store delete*`, `*switch*`,
      `git push --force*`, `rm -rf /*`, `reboot*`, `systemctl stop*`, `mkfs*`, `parted*`, `dd if=*` — these
      hold even under yolo, and the repartition script must be unreachable from the agent.
- [ ] Keep `approvals.unattended_mode = "deny"`; `ssh deployer@ai …` and `nix`/`git` commands are not
      dangerous-shaped, so they pass smart mode without opening anything.
- [ ] A skill documenting the loop for the agent: clone → branch → edit → `nix flake check --no-build` →
      commit → push `agent/*` → `deploy-ai --ref` → read verdict; with the hard "never touch the gate,
      allowlist, secrets, or lock-related paths" rule.

### 6. Validation
- [ ] `nix eval --option eval-cache false '.#nixosConfigurations.buildvm.config.system.build.toplevel.drvPath'`
      and the `buildvm-image` output; `nixosConfigurations.ai` still evaluates.
- [ ] Unit-PATH regression check: `…systemd.services.hermes-agent.path` still contains docker (if kept) and
      now contains openssh.
- [ ] `nix flake check --no-build --option eval-cache false` — must run on `ai`/`git` (this jail cannot fetch
      `secrets.git`; that failure is pre-existing).
- [ ] Storage drill on `ai`: run the script with `--force`, confirm partlabel/mount, confirm `du`/qgroup state
      and that docker (if kept) still starts.
- [ ] VM bring-up drill: `systemctl start buildvm`, ssh from `ai`, then from the gateway unit; `nix eval`
      inside the guest; confirm guest writes hit the partition (`df`, overlay size), not `ai`'s root.
- [ ] Gate drills: `deploy-ai --dry-run` on an out-of-allowlist branch (must refuse with the offending paths),
      on an allowlisted branch (must build); then a real switch of a trivial change; then a forced-failure
      activation in a scratch VM to prove rollback.
- [ ] Lockout drill: verify the recorded previous generation is bootable and the rollback path restores
      `hermes-agent` without human ssh.

### 7. Docs
- [ ] `.ralph/hermes-self-deploy.md`: architecture, decisions, the wipe/rep partition recipe and revert path.
- [ ] `README.md`: add the gated `ai` deploy path beside `nix develop . -c deploy` (README.md:155-158).
- [ ] `AGENTS.md`: `deploy-ai` is the only sanctioned deploy entrypoint; the allowlist lives outside the repo;
      agents must not run the repartition script.

## Notes / risks

- `ai` hosts the agent that deploys it: any bug is also an outage. Hence allowlist-before-build, recorded
  generation, health check, rollback, and the `systemctl reboot --when` style guard.
- The gate is the highest-privilege component (root activation on `ai`). It must live outside the repo and
  outside anything the agent can write, and its allowlist file must not be reachable from the guest.
- Store growth on `ai`'s 256 GiB ext4 root is unavoidable (the active system closure must live there).
  Mitigate with `nix.gc` + generation limits and watch root usage.
- `nix flake update` bumps are not allowlist-safe: keep `flake.lock` out of the agent's allowlist; flake
  updates stay a human task (AGENTS.md post-update workflow).
- virter has no NixOS module: expect to hand-roll the systemd unit and to re-check its CLI flags
  (`virter virt --help`) rather than trusting this plan's flag names.
- If decision 3a lands, the guest carries Xvnc/Xfce/browser; if the bot desktop misbehaves headless, fall
  back to `placement = "gateway"` rather than debugging inside the VM.
