# trilium-git-sync

Bidirectional sync between a [Trilium Notes](https://github.com/TriliumNext/Notes) instance and a git repository.

## What it does

- **Export**: Extracts Trilium's note tree as markdown files into a git repo
- **Import**: Applies upstream git changes back into Trilium
- **Merge**: When both sides have changes, uses git's 3-way merge (cherry-pick) with Trilium winning on conflicts

Each note becomes a directory with a `README.md` (or original filename for file/image notes). Attachments, clones, and the full tree structure are preserved.

## Usage

```bash
# First run: mint an API token
trilium-git-sync --mint-token

# Normal sync (run on a schedule or manually)
trilium-git-sync

# Force full re-export
trilium-git-sync --full-export

# Reset Trilium to match a specific git commit
trilium-git-sync --reset <commit-sha>
```

## Configuration

All options can be set via CLI flags or environment variables:

| Flag | Env var | Default |
|------|---------|---------|
| `--base-url` | `TRILIUM_GIT_SYNC_BASE_URL` | `http://127.0.0.1:8080` |
| `--repo-path` | `TRILIUM_GIT_SYNC_REPO_PATH` | `~/.local/share/trilium-git.git` |
| `--remote-url` | `TRILIUM_GIT_SYNC_REMOTE_URL` | *(none — local only)* |
| `--branch` | `TRILIUM_GIT_SYNC_BRANCH` | `main` |
| `--use-lfs` | `TRILIUM_GIT_SYNC_USE_LFS` | `false` |
| `--home-dir` | `TRILIUM_GIT_SYNC_HOME_DIR` | `$HOME` |

Auth token is cached at `~/.local/state/trilium-git-sync/auth-token`.

## Sync flow

```
1. Fetch upstream
2. Export Trilium changes → commit on local HEAD
3. If upstream diverged:
   a. Cherry-pick export onto upstream (git merges content)
   b. Import upstream-only changes into Trilium
4. Push
```

Trilium wins on line-level conflicts. Non-conflicting changes from both sides are merged automatically.

## Tests

Integration tests run against a live Trilium server (not built into the package):

```bash
TRILIUM_SERVER_BIN=$(nix build --no-link --print-out-paths nixpkgs#trilium-server)/bin/trilium-server
PKG=$(nix build --no-link --print-out-paths .#trilium-git-sync)

TRILIUM_SERVER_BIN=$TRILIUM_SERVER_BIN \
PYTHONPATH=$PKG/libexec \
python3 tests/integration_test.py
```

The tests spin up a disposable Trilium instance in `noAuthentication` mode, exercise the full pipeline (export, import, incremental, merges, moves, deletes, clones, attachments), and tear everything down. ~23 tests, ~5 minutes.

## File layout

```
trilium_git_sync/
  cli.py          # CLI argument parsing
  client.py       # Trilium ETAPI HTTP client
  sync.py         # Main sync orchestrator
  export.py       # Trilium → filesystem (extract, restructure, attachments)
  apply.py        # Filesystem → Trilium (create, update, delete, move)
  manifest.py     # Build manifests, compute pull plans
  meta_tree.py    # !!!meta.json tree navigation/mutation
  rewrite_ids.py  # noteId↔syncId rewriting, clone handling
  git_export.py   # Sparse checkout commit workflow
  git_repo.py     # Bare repo, worktree lifecycle
  git_lfs.py      # LFS tracking helpers
  home_links.py   # file:// link rewriting
  import_zip.py   # Build Trilium-compatible import ZIPs
  common.py       # Logging, constants, utilities
tests/
  integration_test.py  # Live Trilium integration tests
```
