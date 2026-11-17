---
name: commit-style
description: Canonical git commit message rules for the nixflakes repo - scoped lowercase subjects (`overlay: add ...`), imperative verbs, no Conventional Commit types, impersonal declarative body prose (`x was done because y`), and machine-generated flake.lock messages. Use when writing, amending, squashing, or reviewing a commit message in this repo.
---

# Commit Style

`git log --oneline -15` is the source of truth. Match it; do not import Conventional Commits.

## Subject line

- Shape: `<scope>: <imperative action>`. Bare `<imperative action>` only when no single scope fits (repo-wide restructure, `Initial commit`).
- Scope = one lowercase, kebab-case thing you actually touched:
  - hosts: `nas`, `surface`, `jump`, `llm`, `notes`, `git`, `git-runner1`, `wsl`, `mitchpc`, `immich`, `nextcloud`, `jellyfin`
  - repo areas: `flake`, `flake.lock`, `overlay`, `platforms`, `modules`, `home-manager`, `core`, `nixvim`, `cicd`, `pkgs`, `docs`
  - packages/services: `paperless`, `ollama`, `logseq`, `pi-agent`, `incus-backup-rustic`, `azure-storage-explorer`
  - Host scope wins for host-only changes; module/package scope wins when the change is reusable across hosts.
- Verb after the colon: lowercase imperative, from `add`, `create`, `update`, `fix`, `remove`, `disable`, `enable`, `switch`, `move`, `rename`, `patch`, `bump`, `revert`, `configure`. No past tense, no gerunds.
- Never use `feat:`, `fix:`, `chore:`, `BREAKING CHANGE`, issue-number prefixes, or A/B test markers.
- Capitalize only proper nouns and literal identifiers: `KeePassXC`, `DBus`, `gcc.arch`, `wantedBy`, `texliveFull`, `nixpkgs`.
- 30-60 chars target, 72 hard max, no trailing period, no commas-as-clause-stacking beyond 3 items.
- One concern per commit. Banned vague subjects: `Update`, `Random changes from working`, `fixes after update`, `minor ... tweaks`, `misc`.

## Voice

The message records the change, not the person who made it.

- No first or second person anywhere: `I`, `we`, `our`, `you`, `your`, `let's`, `someone`, `I tried`, `we decided`, `my change`. Reword to the thing that changed.
- Declarative, in the shape `x was done` / `y was done because z`:
  - bad: `I made tune follow the engine because I hit an assertion I added`
  - good: `tune now defaults to cfg.prefetchOnStart && !cfg.mockEngine because the vm test runs the module with mockEngine = true`
- Past tense for what the change did and for the state before it; present tense only for behaviour that is now true (`the assertion fires when ...`).
- Concise standard prose. No hedging (`maybe`, `probably`, `should work`), no filler (`note that`, `it's worth mentioning`, `as an aside`), no chatty asides, no exclamation, no emoji.
- Name the mechanism and the consequence, never the actor: `the assertion fires on a mock engine`, not `I made the assertion fire`.
- Subjects keep the imperative verb from the list above (`add`, `fix`, `remove`); the impersonal rule governs the body.

## Body

Write a body when at least one is true:

- the *why* is not in the diff (workaround, hardware failure, upstream bug)
- the commit contains 3+ logically distinct changes
- a new module/package/structure changes how other consumers import it
- a known-broken thing is being left broken on purpose

Skip it for one-line config tweaks, dependency bumps, and obvious fixes.

Format:

- `-` bullets, one clause per bullet, no terminal punctuation on single-clause bullets.
- Nest details under a parent bullet with 2 spaces.
- Multi-area commits: `area: action` per bullet (`- pi-agent: replace eval-time IFD lookups with passthru.extensions`).
- Then optionally one prose paragraph giving the reason, wrapped at ~72 columns, sentences with periods.
- Link upstream issues/PRs and external causes by full URL in the body, never the subject.
- Name the consequence, not just the action: "Leaving this to auto was causing many complicated packages to have timeouts in their tests".

`[ci skip]` as a lone body line is allowed only for docs/comment-only commits.

## flake.lock commits

- Routine bump: subject `flake.lock: Update`, and keep the generated `Flake lock file updates:` bullet block verbatim. Never hand-edit or trim it.
- Bump plus cleanup/fixes: subject `flake: <what you fixed>`, keep the generated block, and add `- area: fix` bullets for the human work.
- Manual override: `flake.lock: manually patch to master` or `flake.lock: revert <reason>`, with the reason (usually a URL) in the body.
- Do not write subjects like `update lock`, `nix flake update`, or `flake update` for lock-only bumps.

## History and tooling

- Linear history: rebase instead of merging; no merge commits.
- Fix message typos with `git commit --amend` before pushing (`pacakge`, `subsituters`, `upstread` are existing mistakes, not style).
- `deploy-<host>` and `deploy-<host>-<timestamp>` tags are produced by `.forgejo/workflows/build.yaml`; never create them by hand.
- Deployment-scoped commits still describe the change, not the deploy (`nas: replace failed drive`, not `deploy nas`).

## Before committing

1. `git log --oneline -15` to confirm scope vocabulary and verb choice.
2. `git diff --cached --stat` and ask: is this one concern, or does it need bullets?
3. Draft subject, check scope exists, verb is imperative, length <= 72, no type prefix.
4. Read the draft for first-person words and hedging; rewrite anything that names an actor.
5. `git commit -F -` with a heredoc for multi-line messages; verify with `git log -1 --pretty=%B`.
6. `git log -1 --pretty=%B | grep -nEi '\b(I|we|our|you|your|let's)\b'` must come back empty before pushing.

See [EXAMPLES.md](EXAMPLES.md) for before/after rewrites of real repo messages.
