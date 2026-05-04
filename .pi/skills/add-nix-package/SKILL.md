---
name: add-nix-package
description: Adds repo-local Nix package derivations for this nixflakes repo under pkgs/, following nixpkgs conventions, preferring upstream nixpkgs when possible, wiring new packages into overlay.nix, and creating update.sh for eligible packages. Use when packaging software into Nix, adding a package under pkgs/, updating a local derivation, or deciding between upstream nixpkgs, overlay overrides, and local packages.
---

# Add Nix Package

Work repo-first. Before asking questions answerable from the tree, inspect `overlay.nix` and nearby packages in `pkgs/`.

## Repo rules

- New local packages live in `pkgs/<kebab-name>/default.nix`.
- Expose new local packages from `overlay.nix` only. Do not add them to `perSystem.packages` unless the user explicitly asks.
- Prefer `kebab-case` for folder name, overlay attr, and `pname`.
- Keep file count minimal:
  - always `default.nix`
  - for deterministic update flows, create `update.sh` by default; skip only with a short reason
  - add patch files or split files such as `frontend.nix` only when clearly justified
- In Nix multiline strings (`'' ... ''`), `${...}` is still Nix interpolation, even inside shell comments or heredocs.
  - Avoid accidental `${...}` in commented shell snippets.
  - If you need a literal `${`, write `''${`.
- Prefer nixpkgs conventions over local convenience, but preserve repo style and minimize diff churn.

## Strategy decision tree

1. Check whether the package already exists in upstream `nixpkgs` locked by this flake.
   - Prefer checking the flake's locked `nixpkgs` input, not an unrelated host/global channel.
   - Upstream availability snippet:
     ```bash
     nix eval --impure --expr '
     let
       flake = builtins.getFlake (toString ./.);
       pkgs = import flake.inputs.nixpkgs {
         system = "x86_64-linux";
         config.allowUnfree = true;
       };
     in builtins.hasAttr "<attr>" pkgs
     '
     ```
   - If upstream is good enough: recommend using upstream and stop.
   - If only a small fix is needed: recommend `override` or `overrideAttrs` in `overlay.nix`.
   - If making a repo-local copy of an upstream package: require an explicit reason.
2. For Node/JS/Pi packages, read upstream `package.json` before choosing the builder.
   - Check at minimum:
     - `name` including scoped names
     - `bin`
     - `pi`
     - lockfile and package manager
     - `files`
   - Also inspect the source tree for runtime file references so required non-code files survive installation.
3. Choose the narrowest correct builder.
   - Python app/service/CLI: `python3.pkgs.buildPythonApplication`
   - Python library: `python3.pkgs.buildPythonPackage`
   - Source-only Pi/Node package that does not need an npm build: prefer `stdenvNoCC.mkDerivation`, then install the package tree into `lib/node_modules/...`
   - JS app/package that really needs dependency install or build: `buildNpmPackage`
   - For npm workspaces/monorepos, keep `src` at the repo root and prefer `npmWorkspace` plus `npmDepsFetcherVersion = 2`.
   - If several local packages share one monorepo, prefer a shared `src.nix` with common `version`/`src` and any shared `npmDepsHash`.
   - Otherwise prefer a specific helper if one clearly fits; fall back to `stdenv.mkDerivation`
4. For Pi/Node modules consumed through `pi-agent.wrap` `extraNodeModules`, inspect `pkgs/pi-agent/wrap.nix` before packaging.
   - If repo helpers expect `lib/node_modules/${pname}` but Node resolution needs the real package name from `package.json`, provide both layouts when necessary.
   - Common case for scoped packages:
     - wrapper discovery path: `lib/node_modules/${pname}`
     - real package resolution path: `lib/node_modules/@scope/name`
   - If helpful, expose `passthru.packageDir` as the real package root.
5. Ask before any major strategy fork, and give a recommended answer:
   - local copy vs upstream override
   - source-only Node package vs npm build
   - simple JS app vs workspace/monorepo
   - app vs library for Python
   - split files vs single `default.nix`
6. Keep tests enabled by default. If Nix-only failures force a skip, disable individual failing tests only and leave a short comment explaining why.
7. Prefer small, reviewable edits. Do not reorder unrelated overlay entries or reformat the repo broadly.

## Hash and source rules

- Prefetch source hashes up front when possible.
- Use ecosystem-specific helpers when available.
- For `buildNpmPackage`, prefer the standard fake-hash loop over ad-hoc prefetching: start with `npmDepsHash = lib.fakeHash;`, build once, copy the `got:` hash from the failure, and rebuild.
- If a dependency hash cannot be prefetched (for example `npmDepsHash`), use the builder error to capture the corrected hash and replace it.
- Inspect source for runtime file references and preserve required non-code files in the output:
  - `package.json`
  - `skills/`
  - `docs/`
  - extension entrypoints
  - assets and templates
  - files listed in `package.json`
- Never leave fake hashes in the final result.
- Never use unpinned fetches or curl-pipe install steps.

## Required package quality

- Set `meta.description`, `meta.homepage`, `meta.license`, and `meta.platforms`.
- Set `meta.mainProgram` when there is a clear primary executable.
- Omit `maintainers` unless there is a deliberate reason to add it.
- Keep derivations reviewable and close to nixpkgs conventions.

## Validation

Prefer `.#...` flake references for repo package validation because they use this repo's locked `nixpkgs` input and the actual exported overlayed package set.

After writing code:

1. If you created a new path referenced by the flake, `git add` it before validation. Flakes only see tracked files.
   - Typical case: `git add pkgs/<name> overlay.nix`
2. Evaluate first to confirm the attr shape and overlay wiring work:
   - `nix eval .#legacyPackages.x86_64-linux.<attr>.drvPath`
3. Build without linking and capture the output path:
   - `out="$(nix build --no-link --print-out-paths .#legacyPackages.x86_64-linux.<attr>)"`
4. Treat build logs as advisory, not proof.
   - Do not treat partial or truncated output as success.
   - Confirm success from exit status.
   - Prefer inspecting `$out` directly.
5. For Pi/Node packages, validate the built runtime layout, not just the build result:
   - `lib/node_modules/<pname>`
   - scoped path such as `lib/node_modules/@scope/name` when needed
   - required runtime files such as `package.json`, `skills/`, `docs/`, extension entrypoints, assets, and other referenced files
   - any expected passthru such as `packageDir`
6. Format touched Nix files only, using the repo formatter rather than a floating nixpkgs formatter: `nix fmt -- <touched-files...>`
7. If the package has a deterministic release/update flow, add `update.sh` and run it or dry-run it when practical.
8. Do not stop after first draft. If eval, build, formatter, or runtime layout validation fails, fix the derivation and rerun until it passes.

## update.sh rules

For packages with a deterministic update flow, add `update.sh` by default.

- Use a `nix shell ... -c bash` shebang style like the repo example.
- For GitHub tag packages, default flow should usually be:
  - find the latest `v*` tag
  - prefetch the unpacked source hash
  - update version and source hash
  - update any ecosystem-specific dependency hashes too
  - for shared monorepo `npmDepsHash`, probe one representative `buildNpmPackage` package with a fake hash and capture the reported `got:` value
  - restore files on failure
- Fail safely and restore files on error when practical.
- Keep it idempotent.
- If you skip `update.sh`, leave a short reason in your summary.

## Do not do these

- Do not duplicate an upstream nixpkgs package without a stated reason.
- Do not silently disable all tests.
- Do not leave fake hashes in committed code.
- Do not inline giant patches when a patch file is clearer.
- Do not add local packages to `perSystem.packages` unless asked.

See [EXAMPLES.md](EXAMPLES.md) for short repo-specific references.
