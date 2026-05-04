# Examples

Read existing repo patterns before inventing a new one:

- Simple Python application: `../../../pkgs/wake-on-lan-api/default.nix`
- Simple JS package: `../../../pkgs/pi-mcp-adapter/default.nix`
- Larger JS package with wrapper/custom build logic: `../../../pkgs/pi-agent/default.nix`
- Scoped Pi/Node package without a bin: `../../../pkgs/pi-ask/default.nix`
- Pi extension/skill packaging and runtime discovery logic: `../../../pkgs/pi-agent/wrap.nix`
- Plain fetched archive / no-compiler packaging: `../../../pkgs/context-mode/default.nix`
- Combined backend + frontend kept in one file: `../../../pkgs/paperless-gpt/default.nix`
- Example update script: `../../../pkgs/pi-agent/update.sh`
- Overlay wiring target: `../../../overlay.nix`

Notes:

- Prefer a single `default.nix` unless splitting files materially reduces complexity.
- `../../../pkgs/paperless-gpt/frontend.nix` does not look like a canonical example; check it carefully before copying that pattern.
- For source-only Pi/Node packages without an npm build, prefer `stdenvNoCC.mkDerivation`, read `package.json` first, and install the package tree into `lib/node_modules/...`.
- For Pi/Node packages used via `extraNodeModules`, make sure output layout supports both `lib/node_modules/${pname}` and the real package path from `package.json` such as `lib/node_modules/@scope/name`.
- When that real package path matters at runtime, `passthru.packageDir` should usually point to it.
- Preserve required runtime files, not just code: `package.json`, `skills/`, `docs/`, extension entrypoints, assets, and files referenced by source or listed in `package.json`.
- In Nix multiline strings, `${...}` still interpolates even inside shell comments; use `''${` for a literal `${`.
- Successful build output is not enough by itself; confirm exit status and inspect the output layout.
- New packages should normally use the same kebab-case name for folder, overlay attr, and `pname`.
- For new flake-visible paths, `git add` them before `nix eval` / `nix build`.
- For eligible packages, create `update.sh` by default.
