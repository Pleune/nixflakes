---
name: deploy-ai
description: Deploy changes you made in this build VM to the `ai` host. Use when asked to deploy,
  roll back, or check what ai is running, or when a deploy or an ssh command to `deployer` is refused.
---

# Deploying `ai` from this VM

You are `builder` inside the build VM on `ai`. You can edit, commit and build here; you cannot
switch `ai` yourself. Everything goes through `deploy-ai`, over ssh, as the `deployer` account on
the host, and the gate vets the patch before anything is applied.

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
ssh -p 22 deployer@10.0.2.2 'deploy-ai --status'       # what ai runs, and any pending rollback
```

`10.0.2.2` is `ai` on the qemu user-mode network, and port 22 is ai's own sshd. Port 2224 is the
forward that reaches *this VM* from ai; `deployer` does not exist there. The key already in
`~builder/.ssh` is the one `deployer` accepts, so no `-i`.

The `|` above is on your side of the ssh. The remote command is the one quoted string.

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
| `deploy-ai: refusing: <reason>` | `deploy-ai` ran and applied nothing; the reason is in the message. |
| `deploy-ai gate: /run/wrappers/bin/sudo is not executable, so nothing can be deployed.` then `deploy-ai gate: ai needs security.sudo.enable for the setuid copy of sudo to exist.` | `ai` has no setuid sudo, so no command can reach `deploy-ai`. Nothing of yours is wrong: the operator's `security.sudo.enable` is the fix. |
| `sudo: /nix/store/…-sudo-…/bin/sudo must be owned by uid 0 and have the setuid bit set` | an `ai` generation whose gate ran sudo from the store instead of `/run/wrappers/bin/sudo`. Report it; your command was fine and nothing ran. |
| `deploy-ai` usage text, exit 1 | No flags it recognized, or an unknown flag. |
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
   `docs/`, `README.md`, `lib/`, `modules/nixos/`, `config/`, `pkgs/`, `skills/`, `platforms/ai.nix` and
   `platforms/buildvm.nix`. Read `cat /etc/deploy-ai/allowlist` instead of trusting this list; it is why
   most of `platforms/` is not yours to change.
4. No changed path is in `/etc/deploy-ai/denylist`: `modules/nixos/deploy-ai/`, `pkgs/deploy-ai/`,
   `flake.lock`, `secrets/`. The thing doing the vetting cannot vet a change to itself.
5. Nothing the patch moves changes the policy the gate runs under. `--vet` prints the digest it
   computed; it must equal `/etc/deploy-ai/policy-digest`. That policy covers the allowlist, the
   gate's and build VM's keys, the users and their authorized keys, sudo, sshd, nix trust, and the
   submit rules — so you cannot widen what is allowed.

Then it builds your tree on this VM, copies the result to ai, runs the health probes against the
build VM, and switches ai only if the probes pass. A switch you did not ask for is rolled back on a
timeout; an explicit switch stays, and a later deploy can roll it back.

## Guest-only changes never restart ai

If every changed file is listed in `/etc/deploy-ai/guest-only-paths` (`platforms/buildvm.nix` and
`platforms/buildvm-bootstrap.nix`), the gate rebuilds this VM, reboots it, and leaves ai alone. Your
session is cut when the VM reboots; reconnect and read `/home/builder/deployed-commit`.

The allowlist is checked before that classification, and `platforms/buildvm-bootstrap.nix` is not on
`ai`'s allowlist, so a patch to that file is refused as outside the allowlist until the operator widens
it. `platforms/buildvm.nix` is on both lists, and is the guest-only change you can send today.

Any other file means ai restarts. `platforms/ai.nix` and everything else are ai's.

## What is recorded, and what survives

- `/home/builder/deployed-commit` — the commit ai (or the guest) was last switched to, written by
  `deploy-ai` over ssh after each successful deploy.
- `/home/builder/nixflakes/DEPLOYED.md` — what provisioning applied, and the tag it moved.
- the `deployed` tag in `/home/builder/nixflakes` — what the guest's provisioning tagged, and what
  `deployed..main` is measured against.
- `/home/builder/provisioned-commit` — the `ai` snapshot provisioning already applied here; while it
  names the snapshot `ai` runs, provisioning does nothing at all.
- ai keeps its own state under `/var/lib/deploy-ai/`: the deployed source, the commit, the pending
  rollback, the last build output and the deploy log.

Provisioning runs on every ai deploy and moves only the `deployed` tag: nothing you committed here is
discarded, nothing is reset, stashed or rewritten, and `main` stays where you left it. Push
(`git push origin main`, or a branch) when your work has to exist outside this VM, because the git host
is where ai's own deploys come from. To put your commits on top of a deploy, `git rebase deployed`.

## When a deploy is refused

`deploy-ai` prints why and applies nothing. Report the reason; do not work around it.

| Message | What it means |
| --- | --- |
| `deploy-ai gate: only 'deploy-ai ...' is accepted here.` | The string sshd passed did not start with `deploy-ai`. Quote the command once, with no shell punctuation in it. |
| `deploy-ai gate: refusing a command containing '<char>'.` | That character is not reachable safely here; send one command per ssh and keep `<char>` out of arguments. |
| `deploy-ai: refusing: --repo is required` | `--list` and `--ref` read a repository: add `--repo <url>`. |
| `the patch does not apply to the deployed commit <base>; rebase it onto <base> and submit again` | Your base moved; rebase onto `deployed`. |
| `refusing: '<path>' is outside the deploy-ai allowlist.` | That file is not yours; ask the operator. |
| `refusing: '<path>' is on the deploy-ai denylist.` | The gate's own code, `flake.lock`, or secrets. |
| `the patch changes the deployment policy (allowlist, keys, users, sudoers); …` | It moves ssh keys, sudo, or the rules above. |
| `patch too large: N bytes, over the M limit in /etc/deploy-ai/submit-max-bytes` | Split the series. |
| `empty patch on stdin; nothing to submit` | `deployed..main` was empty — nothing committed, or you piped from the wrong range. |
| `the guest switch failed; ai is unchanged` | The guest's rebuild or switch failed; ai is untouched. |
| `… is missing; the running system was built without nixflakes.deploy-ai.deployedSource` | ai has no baseline to patch onto; the operator must switch. |
| `deploy-ai: refusing: the CURRENT system is already unhealthy; switching would hide that.  Fix it out-of-band or reboot ai` | The probes on the running system failed before anything was switched. |
| `deploy-ai: the new system never became healthy; switching back`, then `deploy of <sha> failed and was rolled back; log: /var/lib/deploy-ai/log/build.log` | ai switched and came back broken; deploy-ai switched the recorded generation back and cancelled the reboot guard. |

## Checking state

```bash
ssh -p 22 deployer@10.0.2.2 'deploy-ai --status'                        # what ai runs, pending rollback
ssh -p 22 deployer@10.0.2.2 'deploy-ai --repo <url> --list'             # a repository's refs
ssh -p 22 deployer@10.0.2.2 'deploy-ai --repo <url> --ref <rev> --dry-run'
```

The URL for your own work is the checkout on this VM:
`--repo ssh://builder@127.0.0.1:2224/home/builder/nixflakes`.

`--repo`/`--ref` is the operator's route, which fetches from a repository. You normally use
`--submit`; the repository route asks the git host as `builder`, so it only works once your key is
registered there. `--rollback`, `--switch`, `--nix-cache-optimize` and `--local` belong to the
operator, not to you.
