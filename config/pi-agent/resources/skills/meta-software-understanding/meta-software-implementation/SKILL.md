---
name: meta-software-implementation
description: Routes software implementation requests to the right execution skill. Use when the user wants to scaffold a project, debug a failure, run and validate changes, or handle setup workflows such as Rust workspace bootstrap.
---

# Meta Software Implementation

Child skills are nested under this directory so this router skill is the only software-implementation router loaded at startup.

Choose the closest child skill, then read its `SKILL.md` before acting.

- [Debug Helper](./debug-helper/SKILL.md) — structured error analysis, log interpretation, and performance profiling.
- [Rust Workspace Bootstrap](./rust-workspace-bootstrap/SKILL.md) — scaffold a production-ready Rust workspace with CI and release tooling.

## Routing guidance

- Use [Debug Helper](./debug-helper/SKILL.md) when there is a failing command, stack trace, crash, confusing log, or performance issue.
- Use [Rust Workspace Bootstrap](./rust-workspace-bootstrap/SKILL.md) for new Rust projects, workspace scaffolding, or setup-heavy Rust implementation work.
- If a request mixes setup and debugging, choose the child skill that addresses the first blocking step.
- Future Nix flake, devshell, and related setup skills belong under this router.

## Editing constraints

- You default to ASCII when editing or creating files. You introduce non-ASCII or other Unicode characters only when there is a clear reason and the file already lives in that character set.
- You add succinct code comments only where the code is not self-explanatory. You avoid empty narration like "Assigns the value to the variable", but you do leave a short orienting comment before a complex block if it would save the user from tedious parsing. You use that tool sparingly.
- Use `apply_patch` for manual code edits. Do not create or edit files with `cat` or other shell write tricks. Formatting commands and bulk mechanical rewrites do not need `apply_patch`.
- Do not use Python to read or write files when a simple shell command or `apply_patch` is enough.
- You may be in a dirty git worktree.
  * NEVER revert existing changes you did not make unless explicitly requested, since these changes were made by the user.
  * If asked to make a commit or code edits and there are unrelated changes to your work or changes that you didn't make in those files, you don't revert those changes.
  * If the changes are in files you've touched recently, you read carefully and understand how you can work with the changes rather than reverting them.
  * If the changes are in unrelated files, you just ignore them and don't revert them.
- While working, you may encounter changes you did not make. You assume they came from the user or from generated output, and you do NOT revert them. If they are unrelated to your task, you ignore them. If they affect your task, you work **with** them instead of undoing them. Only ask the user how to proceed if those changes make the task impossible to complete.
- Never use destructive commands like `git reset --hard` or `git checkout --` unless the user has clearly asked for that operation. If the request is ambiguous, ask for approval first.
- You are clumsy in the git interactive console. Prefer non-interactive git commands whenever you can.
