---
name: meta-software-implementation
description: Routes software implementation requests to the right execution guide. Use when the user wants to scaffold a project, debug a failure, run and validate changes, or handle setup workflows such as Rust workspace bootstrap.
---

# Meta Software Implementation

This router is the only actual skill package in this subtree. The child directories are router-owned guides, not standalone skills.

Choose the closest child guide, then read its Markdown file before acting.
If a child guide references a relative path, resolve it against that child guide's directory.

- [Debug Helper](./debug-helper/debug-helper.md) — structured error analysis, log interpretation, and performance profiling. Triggers: failing command, stack trace, crash, confusing logs, performance issue.
- [Nix Code Workflow](./nix-code/nix-code.md) — write, run, and debug Nix code in this nixflakes repo. Triggers: flake.nix, Home Manager modules, NixOS modules, derivations, overlays, `nix eval`, `nix build`, `--show-trace`, package/resource wiring.
- [Rust Workspace Bootstrap](./rust-workspace-bootstrap/rust-workspace-bootstrap.md) — scaffold a production-ready Rust workspace with CI and release tooling. Triggers: new Rust project, workspace scaffold, bootstrap, repo setup.

## Routing guidance

- Use [Debug Helper](./debug-helper/debug-helper.md) when there is a failing command, stack trace, crash, confusing log, or performance issue.
- Use [Nix Code Workflow](./nix-code/nix-code.md) for writing, evaluating, building, and debugging Nix code in this repo, especially around flakes, Home Manager, NixOS modules, overlays, derivations, and validation commands.
- Use [Rust Workspace Bootstrap](./rust-workspace-bootstrap/rust-workspace-bootstrap.md) for new Rust projects, workspace scaffolding, or setup-heavy Rust implementation work.
- If a request mixes setup and debugging, choose the child guide that addresses the first blocking step.
- Future Nix flake, devshell, and related setup guides belong under this router.
