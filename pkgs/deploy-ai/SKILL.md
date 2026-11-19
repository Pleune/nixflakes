---
name: deploy-ai
description: Deploy changes you made in this build VM to the `ai` host. Use when asked to deploy,
  roll back, or check what ai is running, or when a deploy is refused.
---

# Deploying `ai` from this VM

You are `builder` inside the build VM on `ai`. You can edit, commit and build; you cannot switch
`ai` yourself. Everything goes through `deploy-ai`, over ssh, as the `deployer` account on the host.

```bash
cd /home/builder/nixflakes
git add -A && git commit -m '…'
git log --oneline deployed..main                      # what you are about to send
```

`deployed` is the tag provisioning moves to the commit `ai` runs, so `deployed..main` is your own
work and nothing else.

## The route you use: submit a patch

Send the series to the host. Nothing reaches ai until the gate has vetted it, so rehearse first.

```bash
git format-patch --stdout deployed..main \
  | ssh -p 22 deployer@10.0.2.2 'deploy-ai --vet'      # checks only, prints the verdict

git format-patch --stdout deployed..main \
  | ssh -p 22 deployer@10.0.2.2 'deploy-ai --submit'   # vet, then apply
```

`10.0.2.2` is `ai` on the qemu user-mode network; port 22 is ai's own sshd, not the 2224 forward
that runs the other way. The key already in `~builder/.ssh` is the one `deployer` accepts, so no `-i`.

`deployer` cannot open a shell: its login shell is a gate that only accepts a `deploy-ai …` command,
so `--submit` has to be the whole command, with the patch on stdin.

sshd hands your command to that gate as one string, so quote it once:
`ssh deployer@10.0.2.2 'deploy-ai --repo <url> --list'`. The gate splits that string into arguments
and refuses anything containing `;`, `&`, `|`, `<`, `>`, `$`, a backtick, or `*` — not as a sandbox,
but so nothing reaches `deploy-ai` that its own argument parser would reject.

## What the gate checks, in order

1. The series applies cleanly onto ai's deployed source, which the gate unpacks from
   `/etc/deploy-ai/deployed-source` — it never trusts your tree.
2. Every changed path is inside the allowlist `/etc/deploy-ai/allowlist`: `flake.nix`, `docs/`,
   `lib/`, `modules/`, `config/`, `pkgs/`, `platforms/`, `skills/`, `README.md`.
3. No changed path is in `/etc/deploy-ai/denylist` — the gate's own module and script, `flake.lock`,
   `secrets/`. The thing doing the vetting cannot vet a change to itself.
4. Nothing the patch moves changes the policy the gate runs under. `--vet` prints the digest it
   computed; it must equal `/etc/deploy-ai/policy-digest`. That policy covers the allowlist, the
   gate's and build VM's keys, the users and their authorized keys, sudo, sshd, nix trust, and the
   submit rules — so you cannot widen what is allowed.
5. The series is capped at `/etc/deploy-ai/submit-max-bytes` (262144 here) and lands in
   `/var/lib/deploy-ai/inbox` as the record of what arrived.

Then it builds your tree on this VM, copies the result to ai, runs the health probes against the
build VM, and switches ai only if the probes pass. A switch you did not ask for is rolled back on a
timeout; an explicit switch stays, and a later deploy can roll it back.

## Guest-only changes never restart ai

If every file in the patch is listed in `/etc/deploy-ai/guest-only-paths` — the two files that
describe this VM (`platforms/buildvm.nix`, `platforms/buildvm-bootstrap.nix`) — the gate rebuilds
this VM, reboots it, and leaves ai alone. Your session is cut when the VM reboots; reconnect and
read `/home/builder/deployed-commit`.

Any other file means ai restarts. `platforms/ai.nix` and everything else are ai's.

## What is recorded, and what survives

- `/home/builder/deployed-commit` — the commit ai (or the guest) is running now.
- `/home/builder/deployed-tag` — its tag.
- ai keeps its own state under `/var/lib/deploy-ai/`: the deployed source, the commit, the pending
  rollback, the last build output and the deploy log.

Provisioning runs on every ai deploy and resets this VM's `main` to the commit ai was built from.
Work that is only committed here is discarded. **Push it** (`git push origin main`, or a branch) if
it must survive; the gate's record only tells you what is live.

## When a deploy is refused

`deploy-ai` prints why and applies nothing. Report the reason; do not work around it.

| Message | What it means |
| --- | --- |
| `deploy-ai gate: only 'deploy-ai ...' is accepted here.` | The string sshd passed did not start with `deploy-ai`. Quote the command once, with no shell punctuation in it. |
| `deploy-ai gate: refusing a command containing '<char>'.` | That character is not reachable safely here; run one command at a time and keep `<char>` out of arguments. |
| `the patch does not apply to the deployed commit <base>; rebase it onto <base> and submit again` | Your base moved; rebase onto `deployed`. |
| `refusing: '<path>' is outside the deploy-ai allowlist.` | That file is not yours; ask the operator. |
| `refusing: '<path>' is on the deploy-ai denylist.` | The gate's own code, `flake.lock`, or secrets. |
| `the patch changes the deployment policy (allowlist, keys, users, sudoers); …` | It moves ssh keys, sudo, or the rules above. |
| `patch too large: N bytes, over the M limit in /etc/deploy-ai/submit-max-bytes` | Split the series. |
| `empty patch on stdin; nothing to submit` | `deployed..main` was empty — nothing committed. |
| `the guest switch failed; ai is unchanged` | The guest's rebuild or switch failed; ai is untouched. |
| `… is missing; the running system was built without nixflakes.deploy-ai.deployedSource` | ai has no baseline to patch onto; the operator must switch. |
| A probe failure or `VM did not become reachable` | ai stays on the old system. |

## Checking state

```bash
ssh -p 22 deployer@10.0.2.2 'deploy-ai --status'                       # what ai runs, pending rollback
ssh -p 22 deployer@10.0.2.2 'deploy-ai --repo <url> --list'            # a repository's refs
ssh -p 22 deployer@10.0.2.2 'deploy-ai --repo <url> --ref <rev> --dry-run'
```

`--repo`/`--ref` is the operator's route, which fetches from a repository. You normally use
`--submit`; the repository route asks the git host as `builder`, so it only works once your key is
registered there. `--rollback`, `--switch`, `--nix-cache-optimize` and `--local` belong to the
operator, not to you.
