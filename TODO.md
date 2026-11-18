# TODO: finish buildvm provisioning

## Objective

Booting `ai` should produce a build VM that is a **usable NixOS machine**: it runs the
`.#buildvm` system (not the bootstrap seed), and `/home/builder/nixflakes` is a real git clone
with history, origin, and a working ssh identity, so the agent can build, commit, push, and —
from inside the guest — `nixos-rebuild switch --flake .#buildvm`.

Today `buildvm-install.service` only seeds the disk from `.#buildvmBootstrap` and copies
`~/.ssh` from `provisionDir` (modules/nixos/virtualisation/buildvm/default.nix:110-194). Nothing
applies the platform, so Hermes finds no repo, no `nh`, no `@wheel` trusted users, and a guest
that cannot sudo.

## Decisions (confirmed with the user)

- Apply path: plain `nixos-rebuild switch --flake .#buildvm` **inside the guest**; `deploy-ai`
  stays host-side and unchanged in purpose.
- Trigger: host-driven. `buildvm-install` keeps doing disk seeding + grafting while the VM is
  stopped; a **new `buildvm-provision.service` after `buildvm.service`** sshes in, switches,
  reboots, and verifies.
- Repo source: ai ships the tree it already has (local git mirrors, cloned into the guest), so
  provisioning needs no guest-side network and no deploy keys for the *clone*.
- One keypair, `ai_buildvm_id_ed25519`, sourced from the secrets repo
  (`ai_buildvm_id_ed25519.age`, decryptable by ai's host key): ai uses it to log into the guest,
  and the guest uses it as `builder`'s `~/.ssh/id_ed25519` to reach the git host.
- Root in the guest: `builder` joins `wheel` with NOPASSWD sudo.
- Deferred: the guest's own agenix identity. The secrets repo is cloned into the guest but the
  guest does not decrypt anything yet (`platforms/buildvm.nix` needs no secrets, and the guest
  does not enable the wireguard module).

## Tasks

### T1 — Single secrets-sourced keypair (ai side)

- `platforms/ai.nix`: `nixflakes.agenix.enable = true;` and
  `age.secrets."ai_buildvm_id_ed25519" = { file = "${private.secrets}/ai_buildvm_id_ed25519.age"; mode = "0640"; group = "hermes"; }`
  so the gateway units can read it (same ownership rule as the key we fixed in the docs).
- Set `nixflakes.virtualisation.buildvm.privateKeyPath` to
  `config.age.secrets."ai_buildvm_id_ed25519".path`, replacing the hand-made
  `/var/lib/buildvm/secrets/id_ed25519` (lib/buildvm/default.nix:34, module default line 55).
- `lib/buildvm/default.nix:16`: replace `publicKey` with the public half of that keypair
  (literal string, taken from `ai_buildvm_id_ed25519.pub`; it is public, so it belongs in the
  repo, and eval stays IFD-free).
- Add `gitHostKey` to `lib/buildvm/default.nix` — the `ssh-ed25519` line for
  `git.pleunetowne.com` (captured once with `ssh-keyscan -p 2223`), so host-key verification of
  the flake-input fetch stops being a manual step.

### T2 — Generate the guest's ssh home instead of copying a directory

In `modules/nixos/virtualisation/buildvm/default.nix`:

- New options: `guestKeyPath` (nullable path, default `cfg.privateKeyPath`), `gitHostKey`
  (string, default `""`), and keep `provisionDir` as an optional operator overlay.
- In `buildvm-install.service`, after mounting the guest root: write
  `id_ed25519` (from `guestKeyPath`, 0600), `id_ed25519.pub`, `authorized_keys` (both from
  `cfg.publicKey`), and `known_hosts` (from `cfg.gitHostKey`) into
  `/home/builder/.ssh` of the mounted guest, `chown -R builder`, then still apply `provisionDir`
  on top if it is non-empty. The existing blind `cp -r` (lines 176-183) becomes the overlay
  branch rather than the primary mechanism.
- Skip `id_ed25519` when `guestKeyPath` is null, with a log line (keeps the module usable before
  the secret exists).

### T3 — Ship the repos into the guest

Same module, same unit, after the ssh graft:

- New options: `repos` = list of `{ name, mirror, origin, home }`, default
  `[ { name = "nixflakes"; mirror = "/var/lib/buildvm/repos/nixflakes"; origin = buildvm.gitHost; home = "nixflakes"; } ,
     { name = "secrets"; mirror = "/var/lib/buildvm/repos/secrets"; origin = "ssh://git@git.pleunetowne.com:2223/mitchpleune/secrets.git"; home = "secrets"; } ]`.
- For each repo: `git clone --mirror <origin> <mirror>` on first boot (or `git fetch --prune`
  afterwards) using `GIT_SSH_COMMAND="ssh -i <guestKeyPath> -o StrictHostKeyChecking=accept-new"`,
  then `git clone --origin origin <mirror> $MNT/home/builder/<home>` **only when that directory
  does not exist**, `git -C ... remote set-url origin <origin>`, `chown -R builder`.
- Mirror failures must not abort the unit (log and continue): a reseed should still boot.
- Result: full history, origin pointing at the git host, so the agent can push immediately.

### T4 — New `buildvm-provision.service`

Add to the same module as `pkgs.writeShellScript` + unit:

- `after = [ "buildvm.service" ]`, `wantedBy = [ "multi-user.target" ]`, `Type = oneshot`,
  `RemainAfterExit = true`, `TimeoutStartSec = 45min`, `User = root`, runs as root because it
  reads the private key (never `ProtectHome`/`PrivateUsers`), ssh flags copied from
  `pkgs/deploy-ai/deploy-ai.sh:246-249` (`BatchMode=yes`,
  `StrictHostKeyChecking=accept-new`, `-p <sshPort>`, `-i <privateKeyPath>`).
- Steps: wait for ssh on `127.0.0.1:<sshPort>`; read `git -C <workdir> rev-parse HEAD`; compare
  with the marker `/home/builder/.nixflakes-provisioned`; if it matches, exit 0.
- Otherwise run in the guest: `sudo nixos-rebuild switch --flake '<workdir>#buildvm'`, write the
  marker with that sha, `sudo reboot`, wait for ssh again, confirm `hostname` is `buildvm` and
  the marker is present, and log the result.
- Guard: refuse to switch when `<workdir>` is missing or `git status --porcelain` is dirty under
  `platforms/buildvm.nix`/`flake.nix`/`flake.lock` — log and exit non-zero instead of switching
  onto a half-written config.
- Options: `provision.enable` (default true), `provisionFlake` (default `buildvm`),
  `provisionMarker` (default `/home/builder/.nixflakes-provisioned`).

### T5 — Make the guest able to build

`platforms/buildvm.nix`:

- `users.users.builder.extraGroups = [ "wheel" ]` and
  `security.sudo.extraRules = [ { users = [ "builder" ]; runAs = "ALL"; } ]` with NOPASSWD;
  rewrite the line-80 comment ("Not in wheel...") to say the agent activates the disposable
  guest, never `ai`.
- `nix.settings.accept-flake-config = true` in the guest so provisioning and `nh` need no flag
  (builder becomes a trusted user via `@wheel`, config/nixos/core/nix:46-47).
- `systemd.tmpfiles.rules` for `/home/builder` ownership sanity if needed; `programs.git` global
  identity stays unset (the agent/you set it) — documented instead.
- Keep `PermitRootLogin = "no"` and `PasswordAuthentication = false`.

### T6 — Docs

`docs/buildvm-ai-setup.md`:

- §2: the keypair now comes from `ai_buildvm_id_ed25519.age`; record that its public half is
  committed in `lib/buildvm/default.nix`, and list the Forgejo deploy-key registration for
  **both** repos (nixflakes read/write, secrets read) as the one manual step.
- §4: replace the hand-generated key procedure with the agenix path + `keysDirectory` note and
  keep the `sudo -u hermes test -r` check; document the generated `known_hosts`.
- §5/§6: replace the manual clone + `nix nixos-rebuild` (typo, line ~197) with "boot, then
  `journalctl -u buildvm-provision -f`".
- §9: reseed checklist gains "delete `/home/builder/.nixflakes-provisioned` is not needed; the
  marker follows the disk image" and "mirrors are refetched on next boot".
- §11: add rows — provision unit stuck waiting for ssh, switch failure, deploy key not
  authorized on the git host, missing `known_hosts`, marker mismatch.

### T7 — Validation

- `nix eval --option eval-cache false .#nixosConfigurations.buildvm.config.system.build.toplevel.drvPath`
- `nix eval --option eval-cache false .#nixosConfigurations.ai.config.system.build.toplevel.drvPath`
- `nix flake check --no-build --option eval-cache false`
- Re-read the module for the invariant "nothing reads a secret at boot except agenix", and
  confirm no IFD was introduced (`publicKey`/`gitHostKey` are literals, not `readFile` of
  `${private.secrets}`).
- Live run on `ai` (you, or a supervised session): reseed per §9, boot, watch
  `journalctl -u buildvm-install -u buildvm -u buildvm-provision`, then check
  `deploy-ai --status`, `nix flake show`, Hermes terminal, `nh`, `git remote -v`.

## Non-goals

- No VM agenix identity, no guest-side decryption of secrets, no wireguard for the guest.
- No changes to `deploy-ai`, `hermes-agent`, or the `ai` gateway units beyond pointing
  `privateKeyPath` at the agenix path.
- No CI, no `--boot`/`deploy-rs` activation of the guest, no `nixos-rebuild --install-bootaloder`
  automation beyond what `switch` already does for the ESP.

## Risks

- Changing the guest's authorized key while an old guest filesystem is still on the disk means
  `deploy-ai`/Hermes lose access until a reseed; a reseed is part of this change.
- `buildvm-install` gains a network dependency (mirror fetch) at boot. Mitigated by failing soft
  and by mirrors living outside the disk image.
- The provision unit reboots the guest at boot time. It is idempotent via the marker, but a
  broken `.#buildvm` config would loop the guest until the config is fixed — hence the dirty-tree
  and marker guards plus the 45-minute unit timeout.
- `nixos-rebuild switch` in the guest builds against the *worktree*, so uncommitted guest edits
  become active. Documented; the alternative (switch to `HEAD`) would surprise the agent.

## Status (implemented)

- [x] T1 agenix on `ai` for `ai_buildvm_id_ed25519` (0640 root:hermes), pubkey read from
      `${private.secrets}/ai_buildvm_id_ed25519.pub` by `lib/buildvm/default.nix`, which now takes
      `{ private ? null }` so `buildvmBootstrap` still evaluates without the secrets input.
- [x] T2 keypair grafted into `~builder/.ssh` (authorized_keys, id_ed25519, id_ed25519.pub).
      `provisionDir` and the `known_hosts` graft are gone: provisioning never talks to the git host.
- [x] T3 first-time clones into the guest from sources already on `ai`: `nixflakes` from
      `deploy-ai`'s mirror (`/var/lib/deploy-ai/repo`), `secrets` as a plain copy of the tree `ai`
      evaluated (`provision.secretsSource = private`).  No mirrors under `/var/lib/buildvm/repos`,
      no network at seed time; `origin` is still the real URL.  (Changed during implementation from
      the `repos = { name, mirror, origin }` design above.)
- [x] T4 `buildvm-provision.service` switches the recorded commit
      (`/home/builder/deployed-commit`, fallback HEAD) with `--override-input private
      /home/builder/secrets`, marks `/home/builder/provisioned-commit`, reboots the guest.
- [x] T5 `builder` in `wheel` + NOPASSWD sudo (`security.sudo.extraConfig`, so sudoers.d stays).
- [x] T6 docs/buildvm-ai-setup.md §2/§4/§5/§6/§9/§11 rewritten.
- [x] T7 `nix flake check --no-build` passes (with `--override-input private /tmp/fake-private`, a
      local stub carrying the two key files); `buildvm` and `ai` toplevel drvPaths evaluate.

Operator prerequisites before the first deploy: commit both key files in the secrets repo and run
`nix flake update private`; reseeding (§9) is required for a guest seeded under the old pubkey.

## Amendment (after the first ai deploy) — the sandbox key is not shareable

T1/T2 as written put one keypair at `0640 root:hermes` and handed it to `deploy-ai`, `buildvm-provision`
and Hermes.  That does not work: ssh ignores a private key the invoking user does not own, so the
`hermes` units got `Load key "…": Permission denied` → `Permission denied (publickey)`, and a
supplementary group cannot fix it (`0640`, `0644`, `0750` on a key you own are all refused).

- The agenix secret is the **guest's outbound identity**: `0600 root`, grafted into
  `~builder/.ssh/id_ed25519`, and used by root's `deploy-ai`.
- `buildvm-install` generates one keypair per host consumer under `loginKeysDir`
  (`/var/lib/buildvm/keys/<name>/id_ed25519`, `loginKeys` attrset with `owner`/`group`), chowns each to
  its owner, and appends every public half plus the guest's public half to `~builder/.ssh/authorized_keys`.
- `buildvm-provision` uses `provision.loginKey` (root's own pair), so its `ConditionPathExists` and
  `KEY=` no longer reference the agenix file; Hermes `terminal.ssh_key` is the `hermes` pair.
