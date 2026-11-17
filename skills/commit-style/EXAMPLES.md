# Examples

Before/after rewrites of real subjects in this history.

| Old (as committed) | Canonical | Why |
| --- | --- | --- |
| `Add subsituters as flake nixConfig` | `flake: add substituters to nixConfig` | typo + missing scope |
| `azure-storage-explorer: add pacakge` | `pkgs: add azure-storage-explorer` | scope is the area touched, not the thing added |
| `Package logseq (db version)` | `pkgs: add logseq (db version)` | `Package` is not an imperative verb in the list |
| `update lock` / `nix flake update` / `flake update` | `flake.lock: Update` | lock bumps have one fixed subject |
| `minor home-manager tweaks` | `home-manager: set stateVersion default from nixos` | vague subject, no actionable change |
| `fixes after update` | `cicd: fix evaluation errors after nixpkgs update` | vague; name the breakage fixed |
| `Remove nextcloud client, zed-overlay` | split: `nextcloud: remove client`, `overlay: remove zed-editor` | two unrelated concerns |
| `Major refactor of modules` | `modules: flatten to one .nix file per module` | "major" says nothing; bullets carry the scale |
| `disable all gcc.arch` | `platforms: disable gcc.arch everywhere` | scope missing, keeps the body's why |
| `don't use deploy-rs from upstread binary cache` | `overlay: stop substituting deploy-rs from upstream cache` | typo, negative phrasing |
| `try to have gitea render ipynb` | `git: enable gitea ipynb rendering` | "try to" hides whether it works; say so in the body |
| `update and fix immich ML` | `immich: fix ML setup` | two verbs; the fix is the point |
| `Support building nix packages with x86-64-v3 on git-runner1` | `git-runner1: build nix packages with x86-64-v3` | scope leads, host already implies nix packages |
| `CICD: retry builds 10x` | `cicd: retry builds 10x` | scopes are lowercase |

## Voice

The change is the subject of the sentence; nobody is.

| Never | Instead |
| --- | --- |
| `I added an assertion and it tripped the check, so I made tune follow the engine` | `the tuning assertion tripped the vm test, so tune now defaults to cfg.prefetchOnStart && !cfg.mockEngine` |
| `We switched to the fork because upstream still fails` | `the fork was used because upstream still evaluates the package by building it` |
| `our service ran with the developer's values` | `the service started with the values measured on the authors' PC` |
| `you can re-measure with --force` | `tuneForce = true re-measures at the next start` |
| `this should fix the CI job` | `the check evaluates the package without realizing it` |
| `I think the runner is offline` | `no run was created for the commit, so the trigger path is the remaining suspect` |

## New package

```
pkgs: add wake-on-lan-api

- python3.pkgs.buildPythonApplication from an upstream GitHub tag
- exposed from overlay.nix only, not perSystem.packages
- dontCheckRuntimeDeps because upstream requirements.txt pins exact versions
```

## Host config with a reason

```
git-runner1: run one nix build job at a time

Leaving max-jobs at auto let several large derivations overlap, and
their test suites hit timeouts under the load.
```

## Flake update plus fixes

Keep the generated block, add human bullets:

```
flake: resolve evaluation errors, IFD, and deprecations after nixpkgs update

- pi-agent: replace eval-time IFD filesystem lookups with passthru.extensions
- flake: remove obsolete home-manager follow from agenix input
- surface: remove deprecated services.displayManager.gdm.wayland option
- nixvim: migrate texlivePackage from deprecated combined scheme to texliveFull
- docs: document IFD prevention and flake update iteration workflow in AGENTS.md

Flake lock file updates:

• Updated input 'nixpkgs':
    'github:NixOS/nixpkgs/...' (2026-02-17)
```

## Workaround with a known limit

```
surface: patch OpenGL driver path for systemd-tmpfiles

systemd-tmpfiles-setup does not create /run/opengl-driver on the first
boot, so the GPU only works after a second manual launch. This hack
closes the gap until upstream sorts out the tmpfiles ordering.
```

## Deliberately unverified

```
git: enable gitea ipynb rendering

Not confirmed working; the notebook renderer still needs a python env
visible to gitea at runtime.
```
