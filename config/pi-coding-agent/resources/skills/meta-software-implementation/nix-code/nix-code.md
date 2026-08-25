# Nix Code Workflow

Use this guide when writing, running, or debugging Nix code in a flake-based repo.

## Pick the owning layer first

Common ownership patterns:

- shared config/data
- Home Manager or NixOS modules
- reusable helpers in `lib/`
- derivations in `pkgs/`

Before editing, identify which layer owns the change and keep the change in that layer. Avoid fixing architecture problems with local hacks in the wrong layer.

## Change loop

1. Read the affected files and nearby patterns first.
2. Make the smallest correct change.
3. Validate with the narrowest useful Nix command.
4. Escalate from `eval` to `build` to runtime smoke tests only as needed.

Useful commands:

```bash
# Check that a flake output still evaluates
nix eval --option eval-cache false .#<output>.drvPath

# Build without creating ./result
nix build --option eval-cache false --no-link .#<output>
```

When changing CLI or runtime behavior, also run a tiny smoke test against the built output.

## Debugging eval and build failures

- Add `--show-trace` when the default error is not enough.
- Use `--option eval-cache false` when repeated evals get noisy or cache state is confusing.
- If you need local-path access in ad hoc expressions, use `--impure` deliberately.
- If a new file is imported and Nix says it is missing or not tracked by Git, `git add` it first. Flakes ignore untracked files.

Common fixes:

- **`Path ... is not tracked by Git`**
  - Cause: the file exists locally but is not in the flake source snapshot.
  - Fix: `git add <path>` and rerun.

- **store path string context errors** like `string ... is not allowed to refer to a store path`
  - Cause: a string key or target path accidentally carries store context.
  - Fix: strip context only where a pure string is truly required, for example with `builtins.unsafeDiscardStringContext`.

- **module / package boundary confusion**
  - Cause: module logic, generic helpers, and derivation logic are mixed together.
  - Fix: move the code to the owning layer before debugging further.

## Validation strategy

- If a setting is shared by multiple consumers, validate every important consumer.
- Prefer `eval` first, then `build`, then a tiny runtime smoke test.
- When a change affects generated files, activation scripts, or projected resources, inspect the built output rather than guessing.

## Working style

- Prefer small refactors with immediate eval/build feedback.
- Search for an existing pattern before introducing a new abstraction.
- When packaging or projecting code, preserve whatever runtime context the code needs: sibling files, manifests, and dependencies often matter just as much as the entrypoint file.
