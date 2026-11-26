---
name: deploy-ai
description: Deploy changes you made in this build VM to the `ai` host. Use when asked to deploy,
  roll back, or check what ai is running, or when a deploy or an ssh command to `deployer` is refused.
---

# Deploying `ai` from this VM

You are `builder` inside the build VM on `ai`. You can edit, commit and build here; you cannot
switch `ai` yourself. Everything goes through `deploy-ai`, over ssh, as the `deployer` account on
the host, and the gate vets the patch before anything is applied.

`deploy-ai` is `pkgs/deploy-ai/deploy-ai.py`, a stdlib-only Python script, and the login shell is
the shell script `pkgs/deploy-ai/gate.nix`. Grepping this tree for `rust` finds `trusted-users`,
`trusts` and the `incus-backup-rustic` package, never this tool: nothing in the deploy path is
written in Rust.

It is not installed in this VM, and `builder` has no sudo — both are deliberate. The CLI lives on
`ai`, and ssh to `deployer` is the only way to run it, so `which deploy-ai` finding nothing here is
the expected result, not a broken deploy. A local copy would still be vetted by the same gate over
the same ssh, so installing one buys nothing. The `deploy` binary you may see in your PATH is
`deploy-rs`, packaged for the guest's own flake deployments: it has no target for `ai`, it does not
vet anything, and it is not this path.

## Before you send anything

```bash
cd /home/builder/nixflakes
cat DEPLOYED.md                      # what provisioning applied, if anything did
grep -qxF 'DEPLOYED.md' .git/info/exclude || echo 'DEPLOYED.md' >> .git/info/exclude
git add -A && git commit -m '…'
git log --oneline deployed..main     # must list your commits; empty means nothing to send
git diff --stat deployed..main       # every path here has to be on the allowlist
```

`DEPLOYED.md` is provisioning's note, written after a switch succeeds: the commit that is live, the tag
`deployed`, the `ai` snapshot, the UTC time, and that commit's subject. It is not part of the repository,
and it is the only notice you get: `buildvm-provision.service` is a system unit on `ai`, so its journal
belongs to root there, and this VM's own journal ends at the reboot that follows a successful switch.
Keep it out of your commits, because a patch that adds a path outside the allowlist is refused whole;
the exclude line above is what makes `git add -A` skip it.

Provisioning moves only the `deployed` tag. It never touches `main`, `HEAD`, your working tree or your
stash, so your commits and your uncommitted edits are exactly where you left them after a deploy. Read
what is live with `git log -1 deployed` and put your work on top of it with `git rebase deployed`.

`deployed` names the commit `ai` runs, so `deployed..main` is your own work and nothing else. A patch
series is accepted only if all four hold:

1. it applies onto the commit `ai` runs, so it must be based on `deployed` — rebase first if
   `deployed..main` is not a straight line of your commits;
2. every changed path is on the allowlist and none is on the denylist;
3. it does not change the deployment policy (keys, users, sudo, sshd, the allowlist itself);
4. the whole series is under `/etc/deploy-ai/submit-max-bytes`.

Rehearse, then send. Nothing is applied until `--submit` passes the same checks:

```bash
git format-patch --stdout deployed..main \
  | ssh -p 22 deployer@10.0.2.2 'deploy-ai --vet'      # checks only, prints the verdict

git format-patch --stdout deployed..main \
  | ssh -p 22 deployer@10.0.2.2 'deploy-ai --submit'   # vet, then build, probe, switch

cat /home/builder/deployed-commit                      # what the guest runs now
ssh -p 22 deployer@10.0.2.2 'deploy-ai --status'       # what ai runs, and what the next boot runs
```

`10.0.2.2` is `ai` on the qemu user-mode network, and port 22 is ai's own sshd. Port 2224 is the
forward that reaches *this VM* from ai; `deployer` does not exist there. The key already in
`~builder/.ssh` is the one `deployer` accepts, so no `-i`.

The `|` above is on your side of the ssh. The remote command is the one quoted string.

Sessions served by the api server (the WebUI) are request/response: the adapter declares
`supports_async_delivery = False`, so a background `--submit` never sends you a completion notice —
a deploy that "never notified" was not lost, it just had no one to notify.  Launch it in the
background anyway (the ssh dies at activation by design) and pull the outcome yourself:
`process_manage(action='wait'/'poll')` on the session id, then `deploy-ai --status` and
`curl http://10.0.2.2:8642/health`.  Push-capable surfaces (Telegram, Discord) do get the notice.

## Reading the answer

Every run ends with one line that says what happened, so you never have to infer it from prose:

| Last line | Meaning |
| --- | --- |
| `result: ok` | Nothing was applied: a `--status` read, a `--list`, or a `--vet`/`--dry-run`. |
| `result: applied` | A system switched. |
| `result: refused` | A guard said no to your patch. It is on stderr, after the rows that already held. |
| `result: failed` | The patch passed the guards and something afterwards broke: a build on `ai`, a switch, or a health probe. |

Above it, `--vet` and `--submit` report one row per check as that check passes:

```text
deploy-ai: --vet: 1a2b3c4d5e onto 8e4d0a1299
  size      3.4K of 256.0K allowed
  applies   cleanly
  scope     inside the allowlist
  denylist  clear
  policy    unchanged
  changed   platforms/ai.nix
  would     build on ai, switch ai, and reboot back if it never becomes healthy
```

A refusal lands after the rows that held, so the last row you saw is the check that passed and the
refusal is the next one. `--status` answers what is live:

```text
deploy-ai: ai now
  commit    fccc472c1a
  system    /nix/store/y0hi…-nixos-system-ai-26.11.20261107.f4a03c0
  health    ok
  boot      runs the running generation
  guest     1a2b3c4d5e
  baseline  /nix/store/pbw0…-nixflakes-source (present)
  policy    locked; a patch cannot change it
  allowed   platforms/ai.nix platforms/buildvm.nix platforms/buildvm-bootstrap.nix lib/ modules/nixos/ config/ pkgs/ flake.nix skills/ docs/ README.md
  last      2026-11-19T20:04:11  fccc472c1a  submit
  guard     none armed
```

The `system` row reads `/run/current-system`: after a switch made outside the gate it can
disagree with `commit`, and that disagreement is exactly what `--confirm-boot` repairs.  `health`
names what is down — a unit by name, or the health endpoint and the status it answered
(`health endpoint answered 404` is a wrong path, `health endpoint answered nothing` is nothing
listening) — `guest` says what the VM reports it runs, read over ssh from the guest (and says the ssh
failed rather
than pretending the VM has nothing deployed), `boot` says what the next boot runs — the rollback is
the bootloader's default, so a line naming another entry means a reboot takes ai back to that
generation — and `guard` shows the timed reboot that catches a hung
switch.  What counts as healthy is published by the host, not guessed by this package:
`/etc/deploy-ai/health-units` lists the units and `/etc/deploy-ai/health-url` names the endpoint
that must answer 2xx or 3xx, both set by `nixflakes.deploy-ai.healthUnits`/`healthUrl`.

## Addressing the gate

`deployer` has no shell: its login shell is the gate, which takes the single string sshd hands it,
splits it into arguments, and runs
`/run/wrappers/bin/sudo -n /run/current-system/sw/bin/deploy-ai <those arguments>`. That sudo is the
setuid copy NixOS puts under `security.wrapperDir`; a bare `sudo` on sshd's PATH is the read-only copy in
the store, and sudo refuses to run without the setuid bit. So: quote it once, send one command per ssh,
and keep shell punctuation out of the string.

| Command | Result |
| --- | --- |
| `ssh -p 22 deployer@10.0.2.2 'deploy-ai --status'` | works |
| `ssh -p 22 deployer@10.0.2.2 deploy-ai --status` | works too — ssh joins the words — but a local `*` or `$` expands before ssh sees it, so quote |
| `ssh -p 22 deployer@10.0.2.2 'deploy-ai --list'` | refused: `--list` reads a repository, so it needs `--repo <url>` |
| `ssh -p 22 deployer@10.0.2.2 'deploy-ai --status; echo done'` | refused by the gate: `;` |
| `ssh -p 22 deployer@10.0.2.2 'deploy-ai --vet && deploy-ai --status'` | refused by the gate: `&&` |
| `ssh -p 22 deployer@10.0.2.2 'deploy-ai --submit > /tmp/out'` | refused by the gate: `>`; `--submit` writes its own record under `/var/lib/deploy-ai/inbox` |
| `ssh -p 22 deployer@ai 'deploy-ai --status'` | works from inside this VM only if `ai` resolves; prefer the explicit `deployer@10.0.2.2` |

The gate refuses `;`, `&`, `|`, `<`, `>`, `$`, a backtick and `*` because they cannot reach
`deploy-ai`'s parser intact, not as a sandbox. Two commands in one ssh is not a thing you can do
here: send them one at a time.

**Read who said no.** They mean different problems:

| You see | What happened |
| --- | --- |
| `deploy-ai gate: only 'deploy-ai ...' is accepted here.` | The string did not start with `deploy-ai`. Nothing was attempted. Fix the string, not your keys. |
| `deploy-ai gate: refusing a command containing '<char>'.` | Same: the command never reached `deploy-ai`. |
| `deploy-ai: refusing: <reason>` | `deploy-ai` ran and applied nothing; the reason is in the message, and the run ends `result: refused`. |
| `deploy-ai: failed: <reason>` | Your patch passed every guard, then something broke: `build failed on ai; log: …`, `the build output does not match what ai evaluated`, `the switch failed`, `system is unhealthy after the switch; rolled back to …`. Ends `result: failed`. Report the reason; ai is unchanged unless the message says a switch happened. |
| `deploy-ai gate: /run/wrappers/bin/sudo is not executable, so nothing can be deployed.` then `deploy-ai gate: ai needs security.sudo.enable for the setuid copy of sudo to exist.` | `ai` has no setuid sudo, so no command can reach `deploy-ai`. Nothing of yours is wrong: the operator's `security.sudo.enable` is the fix. |
| `sudo: /nix/store/…-sudo-…/bin/sudo must be owned by uid 0 and have the setuid bit set` | an `ai` generation whose gate ran sudo from the store instead of `/run/wrappers/bin/sudo`. Report it; your command was fine and nothing ran. |
| `deploy-ai` usage text, exit 1 | No flags it recognized, or an unknown flag. |
| `bash: deploy-ai: command not found` inside this VM | Expected: the CLI is on `ai`, not here. Run it through ssh to `deployer` above. Nothing to install, and `deploy` (deploy-rs) is a different tool that cannot reach `ai`. |
| `Permission denied (publickey)` | A real key problem: the key in `~builder/.ssh` is not the one `deployer` accepts (`nixflakes.deploy-ai.publicKey`). `ls -l ~/.ssh` first — ssh ignores a key that is group-readable. |

Do not "work around" a refusal by patching the checkout yourself. `git apply`/`patch` onto
`/home/builder/nixflakes` leaves `.rej` and `.orig` files behind, and the tree there is not what the
gate vets — the gate applies your series onto ai's own deployed source, which it unpacks from
`/etc/deploy-ai/deployed-source`. If you want to test locally, use `git apply --check` and clean up
after yourself.

## What the gate checks, in order

1. The series is capped at `/etc/deploy-ai/submit-max-bytes` (262144 here) and an empty one is refused.
   It lands in `/var/lib/deploy-ai/inbox` as the record of what arrived.
2. The series applies cleanly onto ai's deployed source, which the gate unpacks from
   `/etc/deploy-ai/deployed-source`. It never trusts your tree.
3. Every changed path is inside the allowlist `/etc/deploy-ai/allowlist`. On `ai` that is `flake.nix`,
   `docs/`, `README.md`, `lib/`, `modules/nixos/`, `config/`, `pkgs/`, `skills/`, `platforms/ai.nix`,
   `platforms/buildvm.nix` and `platforms/buildvm-bootstrap.nix`. Read `cat /etc/deploy-ai/allowlist`
   instead of trusting this list; it is why most of `platforms/` is not yours to change.
4. No changed path is in `/etc/deploy-ai/denylist`: `modules/nixos/deploy-ai/`, the gate's code and
   tests under `pkgs/deploy-ai/` (`deploy-ai.py`, `gate.nix`, `default.nix`, the two test files),
   `flake.lock`, `secrets/`. The thing doing the vetting cannot vet a change to itself -- but the
   gate's own `SKILL.md` is deliberately NOT denied: it is documentation you maintain, and once
   this carve-out is deployed it rides `--submit` like any doc change. Editing the denylist itself
   moves the policy digest, so that change ships only from a merge-reviewed trusted tip.
5. Nothing the patch moves changes the policy the gate runs under. That policy covers the allowlist,
   the gate's and build VM's keys, the users and their authorized keys, sudo, sshd, nix trust, the build
cap, and the submit rules — so you cannot widen what is allowed. It is fixed on `ai`, and no patch can
move it: `--vet` reports `policy unchanged` rather than a hash, because the hash is not something you act
on.

Then it builds your tree on ai — on the host, capped by `/etc/deploy-ai/build-max-jobs` — and
switches ai only if the probes pass.
Before the switch the probes cover the whole road — ai's units, its health endpoint, and the build VM
being reachable, because switching ai makes provisioning rebuild the VM from this tree.  After the
switch only ai is judged: switching ai
restarts `buildvm-provision`, which rebuilds the guest's system from ai's tree and reboots it, and a VM
down mid-convergence is not a failed deploy. A switch you did not ask for is rolled back on a timeout; an
explicit switch stays, and a later deploy can roll it back.

## A change to the VM still goes through ai

There is no separate guest route.  A patch touching only `platforms/buildvm.nix` or
`platforms/buildvm-bootstrap.nix` is built and switched on `ai` like any other: those files describe a
configuration *object* on `ai`, not a system `ai` runs, so applying them restarts the api server's units
but changes nothing it actually runs.  Both files are on `ai`'s allowlist.

The VM takes the change when `buildvm-provision` runs next — the switch you just made restarts it, so it
builds the guest's own configuration from the source ai was built from, re-tags `deployed`, rewrites
`/home/builder/deployed-commit`, and reboots the guest (docs/buildvm-ai-setup.md §6, §8).  That reboot
cuts your session: reconnect and read the marker.  Nothing schedules provisioning besides that restart
and boot, so a change can sit in the guest's system until ai switches again or the VM reboots.

## What is recorded, and what survives

- `/home/builder/deployed-commit` — what the guest was last converged onto, written by
  `buildvm-provision`; the gate only reads it.  While a deploy's switch is running, provisioning
  takes the commit from `/var/lib/deploy-ai/pending-commit` — the gate writes it just before the
  switch and removes it once the new system is recorded — because a patch deploy carries no
  `self.rev`, and without that file the guest record names whatever the *previous* deploy recorded.
- `/home/builder/nixflakes/DEPLOYED.md` — what provisioning applied, and the tag it moved.
- the `deployed` tag in `/home/builder/nixflakes` — what the guest's provisioning tagged, and what
  `deployed..main` is measured against.
- `/home/builder/provisioned-commit` — the `ai` snapshot provisioning already applied here; while it
  names the snapshot `ai` runs, provisioning does nothing at all.
- ai keeps its own state under `/var/lib/deploy-ai/`: the deployed source, the commit, the
  recorded rollback target, the last build output and the deploy log.  The record moves only after
  the new system is healthy — the switch tail runs as a transient systemd unit, so the ssh session
  activation cuts cannot strand it.  The rollback itself is systemd-boot's `default`: the gate pins
  it to the running generation before switching and releases the pin once health passes, so any
  reboot between those two boots the old generation by itself, and nothing rewrites the pin at
  boot.  A deploy that died, or a switch you made outside the gate, leaves the pin where it was: run
  `deploy-ai --confirm-boot` to point the next boot at the generation actually running.

Provisioning runs on every ai deploy and moves only the `deployed` tag: nothing you committed here is
discarded, nothing is reset, stashed or rewritten, and `main` stays where you left it. Push
(`git push origin main`, or a branch) when your work has to exist outside this VM, because the git host
is where ai's own deploys come from. To put your commits on top of a deploy, `git rebase deployed`.

## When a deploy is refused

`deploy-ai` prints why and applies nothing, ending `result: refused`. A run that got past the guards
and then broke ends `result: failed` instead; both are on stderr. Report the reason; do not work
around it.

| Message | What it means |
| --- | --- |
| `deploy-ai gate: only 'deploy-ai ...' is accepted here.` | The string sshd passed did not start with `deploy-ai`. Quote the command once, with no shell punctuation in it. |
| `deploy-ai gate: refusing a command containing '<char>'.` | That character is not reachable safely here; send one command per ssh and keep `<char>` out of arguments. |
| `deploy-ai: refusing: --repo is required` | `--list` and `--ref` read a repository: add `--repo <url>`. |
| `the patch does not apply to the deployed commit <base>; rebase it onto <base> and submit again` | Your base moved; rebase onto `deployed`. |
| `refusing: '<path>' is outside the deploy-ai allowlist.` | That file is not yours; ask the operator. |
| `refusing: '<path>' is on the deploy-ai denylist.` | The gate's own code or tests, `flake.lock`, or secrets — not `pkgs/deploy-ai/SKILL.md`, which is editable. |
| `the patch changes the deployment policy (allowlist, keys, users, sudoers); …` | It moves ssh keys, sudo, or the rules above. |
| `patch too large: N bytes, over the M limit in /etc/deploy-ai/submit-max-bytes` | Split the series. |
| `empty patch on stdin; nothing to submit` | `deployed..main` was empty — nothing committed, or you piped from the wrong range. |
| `build failed on ai; log: /var/lib/deploy-ai/log/build.log` | The build ran on ai and broke; nothing was switched. The log holds the tails of both streams. |
| `the build output does not match what ai evaluated: <built>, expected <evaluated>; nothing was switched` | The tree built into something other than what the evaluation says it should. Nothing was switched; check what the patch changed about the system's identity. |
| `… is missing; the running system was built without nixflakes.deploy-ai.deployedSource` | ai has no baseline to patch onto; the operator must switch. |
| `deploy-ai: refusing: the CURRENT system is already unhealthy (<what failed>); switching would hide that.  Fix it out-of-band or reboot ai` | The probes on the running system failed before anything was switched.  The parenthesized reason names it: an inactive unit, a status code, no listener, or no configured endpoint. |
| `deploy-ai: the new system never became healthy; switching back`, then `deploy-ai: failed: deploy of <sha> failed and was rolled back; log: /var/lib/deploy-ai/log/build.log` | ai switched and came back broken; deploy-ai switched the recorded generation back and cancelled the reboot guard. |
| `deploy-ai-switch.service: Failed at step EXEC ... 203/EXEC` (journal on `ai`) | The gate handed systemd-run a path it cannot exec — older gates handed over their own store `.py`, which is mode 0444 and refused even for root. Fixed gates re-enter through `/run/current-system/sw/bin/deploy-ai`. Nothing was switched; the boot pin sends the next reboot to the running generation. Report it. |
| `buildvm-provision: warning: exit 4, user units could not reload; the guest switched anyway` | Harmless: the guest switched and only a user-unit reload failed (the user manager is down on the pre-switch config). Provisioning continues. |
| `buildvm-provision: switch failed (exit <n>); guest left as it is` for n other than 4 | The guest switch genuinely failed; ai activation fails with it and the deploy rolls back. Check `journalctl -u nixos-rebuild-switch-to-configuration` on the guest. |
| `another deploy-ai is running (pid <n>)` | Another gate is live right now.  A lock left behind by a gate killed mid-deploy names a dead pid and is reclaimed by the next run, so this row always means a concurrent deploy. |
| `the system is unhealthy after the failed switch; the reboot guard stays armed` | Activation broke partway and the running system failed its own probes.  The boot pin names the previous generation and the guard's timed reboot restores it — reboot now to restore sooner. |
| `deploy of <sha> failed and the switch-back also failed; the reboot guard stays armed` | The switcher itself broke.  Only the pinned old generation boots; the guard's reboot restores it — reboot, then investigate. |
| `deploy-ai: warning: the guard reboot is still scheduled; run ...` | The cancel could not clear logind's schedule. Historical gate generations used `systemctl cancel`, which since systemd ~258 is the *job*-cancel verb (`Manager.ClearJobs`): it exits 0 and leaves `/run/systemd/shutdown/scheduled` untouched, so every deploy left a reboot armed. Stand it down out-of-band on ai with `sudo shutdown -c` — the only command reaching logind's `CancelScheduledShutdown`; `systemctl cancel`/`--when` are no-ops there (root only; the schedule reboots the pinned — healthy — generation, so it is not dangerous, just unwanted) — then deploy the fix: the next healthy switch's tail stands the guard down itself. |
| `buildvm-provision: guest did not come back after the switch; nothing recorded` | The guest wedged booting the new generation.  Nothing is recorded, the marker stays at the old snapshot, and the unit is left failed: `sudo systemctl restart buildvm-provision` on ai converges again after a fix, and the next deploy reruns provisioning by itself. |
| `buildvm-provision: failed: the guest still boots <path>, not <path>` | The guest's loader default pointed at an older generation and re-pinning it once did not fix the boot.  Nothing is recorded; fix the guest's boot entries, then rerun provisioning. |
| `--status` shows `boot pinned to <entry>` after an out-of-band switch | The manual switch never moved the boot pin, so a reboot boots the generation before it. Run `deploy-ai --confirm-boot` on ai. |
| Browser units sit at `start-limit-hit` and `systemctl start` refuses them | During provisioning's converge the units crashed and hit the default start-limit; `switch-to-configuration` never calls reset-failed. The units now set `StartLimitIntervalSec=0`, so a switch restarts them on its own. |
| `refusing: no systemd-boot entry names the running system; nothing to confirm` | A switch activated a generation whose loader entry was never written (the installer runs on `boot` actions, not on plain switches). New gates install the entry (`switch-to-configuration boot`) inside `--confirm-boot` before pinning, so deploy the fix and re-run `--confirm-boot`; meanwhile the machine is healthy and a reboot just boots the newest entry. |
| a port a deploy added answers inside the guest but nothing on ai, after a successful switch | Forward-only edits change nothing else in the qemu unit, and activation compares unit files, so qemu kept the old command line. New gates restart `buildvm.service` after a healthy switch when the live forwards differ from the installed unit; until then `sudo systemctl restart buildvm.service` on ai. |
| a guest-side regression (zram/max-jobs gone, lingering off, browser units failing) reaches production anyway | `checks.x86_64-linux.buildvm-guest-boot` boots the guest's real platform config under UEFI and asserts all of it; `checks.x86_64-linux.deploy-ai-gate-boot` does the same for the gate (dead-lock reclaim, exact-id boot pin). Both *run* qemu during the build, so run them on ai or CI — `nix build .#checks.x86_64-linux.buildvm-guest-boot`. Run both before submitting anything that touches `platforms/buildvm.nix` or the gate module. |

## Checking state

```bash
ssh -p 22 deployer@10.0.2.2 'deploy-ai --status'                        # what ai runs, its health, what the next boot runs
ssh -p 22 deployer@10.0.2.2 'deploy-ai --repo <url> --list'             # a repository's refs
ssh -p 22 deployer@10.0.2.2 'deploy-ai --repo <url> --ref <rev> --dry-run'
```

`--status` prints one row per question (see Reading the answer) and nothing else, so read the rows
rather than grepping them.

The URL for your own work is the checkout on this VM:
`--repo ssh://builder@127.0.0.1:2224/home/builder/nixflakes`.

`--repo`/`--ref` is the operator's route, which fetches from a repository. You normally use
`--submit`; the repository route asks the git host as `builder`, so it only works once your key is
registered there.  There is no `--rollback` or `--switch` to reach for: a deploy that never becomes
healthy rolls itself back — by the tail, and by the bootloader default the gate pins while the
switch is unconfirmed.  ai builds ai's own system; the guest's system is built on the VM and
provisioned from ai's tree by every ai switch.

## Trusted deploys from `main`

`/etc/deploy-ai/trusted-sources` lists repo+branch pairs (`nixflakes.deploy-ai.trustedSources`)
whose current tip may deploy as-is: the operator reviews that branch when a PR merges, so merge
review replaces the allowlist for `deploy-ai --repo <url> --ref <branch>` runs whose commit is
the branch tip.  You cannot push `main` -- that is what makes the trust safe.  The dangerous-change
route is therefore: open a PR (`git push origin HEAD:refs/for/main/<desc>`), the operator merges,
then

```bash
deploy-ai --repo https://git.pleunetowne.com/mitchpleune/nixflakes.git --ref main
```

applies whatever landed, even changes to the gate's own paths.  The health probe, rollback, and
reboot guard still run on every route, and `--submit` patches stay fully vetted: trust belongs to
the reviewed branch, never to a patch.

When you are asked for a feature built on commits the operator has already merged into upstream
`main`, the order is fixed: deploy the trusted route above FIRST to bring ai onto the merged tip,
then `git fetch origin && git rebase deployed` here — `deployed` now names that tip — then deploy
your own commits on top as usual (`--submit` from `deployed..main`). Rebasing onto the merged main
and submitting BEFORE the trusted deploy is refused: the patch does not apply onto the commit ai
runs, because ai still runs the old one. The same rule guards trust from below: only the merged tip
of a trusted branch is trusted, so your unmerged commits stay fully vetted either route.
