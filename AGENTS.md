# nixflakes repo guidance

This file contains repo-specific guidance for agents working in this repository.

## Architecture boundaries

- Put consumer-neutral config in `config/<name>/`.
- Keep `config/home-manager/` for configuration for home-manager modules (from `modules/home-manager/` or upstream home-manager).
- Keep `modules/home-manager/` and `modules/nixos/` for heavy module logic.
- Keep reusable non-derivation helpers in `lib/`.
- Keep `pkgs/` focused on derivation-producing package code and direct package inputs.
- Avoid adding `default.nix` shims in shared config folders when consumers can import the concrete file directly.

## Nix validation

When changing Nix code, prefer the smallest useful validation first.

Typical checks in this repo:

```bash
nix eval --option eval-cache false .#packages.x86_64-linux.<name>.drvPath
nix eval --option eval-cache false '.#homeConfigurations."u322762".activationPackage.drvPath'

nix build --option eval-cache false --no-link .#packages.x86_64-linux.<name>
nix build --option eval-cache false --no-link '.#homeConfigurations."u322762".activationPackage'
```

For shared config changes, validate every affected consumer. Important outputs include:

- `.#packages.x86_64-linux.mitchpi`
- `.#packages.x86_64-linux.mitchvim`
- `.#homeConfigurations."u322762".activationPackage`

When changing `mitchpi`, run a tiny smoke test after building, for example:

```bash
out=$(nix build --option eval-cache false --no-link --print-out-paths .#packages.x86_64-linux.mitchpi)
"$out/bin/pi" -p "hello" </dev/null
```

## Flake workflow gotchas

- New files must be git-tracked before flakes can see them.
- If Nix reports a path is not tracked, `git add` it and rerun.
- This repo often benefits from `--option eval-cache false` during repeated debugging.

## Pi-specific repo notes

- Shared Pi config lives under `config/pi-agent/`.
- Repo-managed Pi resources live under `config/pi-agent/resources/`.
- The Home Manager adapter for that shared Pi config lives in `config/home-manager/terminal/pi-agent/default.nix`.
- Home Manager-specific pi-agent logic lives in `modules/home-manager/terminal/pi-agent/`.
- `mitchpi` and Home Manager `pi` both consume raw `pkgs.pi-agent` plus shared projections from `lib/pi-agent/`.
- Packaged Pi extensions with nested entrypoints may need a projected package root, not just a bare `src/` bind, so runtime imports and bundled dependencies still work.
- For pi-agent mutable state in the jail, prefer explicitly mounted mutable subpaths instead of binding the entire host `~/.pi` tree.

## Node packaging note

- In this repo's pinned nixpkgs, `pkgs.nodePackages` is not a practical dependency source for this work. Prefer explicit npm/pnpm packaging helpers instead.
