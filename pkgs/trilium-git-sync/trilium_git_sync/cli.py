from __future__ import annotations

import argparse
import os
import socket
import sys
from dataclasses import dataclass
from pathlib import Path

from .common import env_flag, env_or


def resolve_path(value: str) -> Path:
    path = Path(value).expanduser()
    if path.is_absolute():
        return path
    return Path(os.environ.get("HOME", str(Path.home()))) / path


@dataclass(frozen=True)
class SyncConfig:
    base_url: str
    root_note_id: str
    repo_path: Path
    worktree_root: Path
    remote_url: str | None
    branch: str | None
    state_dir: Path
    export_subdir: str
    token_name: str
    mint_token: bool
    use_lfs: bool
    fix_gitattributes: bool
    full_export: bool
    reset_commit: str | None
    home_dir: Path | None
    executable_name: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="trilium-git-sync",
        description="Export Trilium notes into a bare git repo via a temporary worktree and push local updates.",
    )
    parser.add_argument(
        "--base-url",
        default=env_or("TRILIUM_GIT_SYNC_BASE_URL", "http://127.0.0.1:8080"),
        help="Base URL of the running Trilium server.",
    )
    parser.add_argument(
        "--root-note-id",
        default=env_or("TRILIUM_GIT_SYNC_ROOT_NOTE_ID", "root"),
        help="Root note ID to export.",
    )
    parser.add_argument(
        "--repo-path",
        default=env_or(
            "TRILIUM_GIT_SYNC_REPO_PATH",
            env_or("TRILIUM_GIT_SYNC_DEFAULT_REPO_PATH", ".local/share/trilium-git.git"),
        ),
        help="Persistent bare git repository path. Relative paths resolve under $HOME.",
    )
    parser.add_argument(
        "--worktree-root",
        default=env_or(
            "TRILIUM_GIT_SYNC_WORKTREE_ROOT",
            env_or("TRILIUM_GIT_SYNC_DEFAULT_WORKTREE_ROOT", ".local/state/trilium-git-sync/worktrees"),
        ),
        help="Root directory for temporary sync worktrees. Relative paths resolve under $HOME.",
    )
    parser.add_argument(
        "--remote-url",
        default=env_or("TRILIUM_GIT_SYNC_REMOTE_URL", env_or("TRILIUM_GIT_SYNC_DEFAULT_REMOTE_URL")),
        help="Remote git URL. If unset, a local repo is initialized and pushes are skipped.",
    )
    parser.add_argument(
        "--branch",
        default=env_or("TRILIUM_GIT_SYNC_BRANCH"),
        help="Branch to use. Defaults to the checkout's current branch.",
    )
    parser.add_argument(
        "--state-dir",
        default=env_or("TRILIUM_GIT_SYNC_STATE_DIR", ".local/state/trilium-git-sync"),
        help="State directory for locks and cached auth tokens.",
    )
    parser.add_argument(
        "--export-subdir",
        default=env_or("TRILIUM_GIT_SYNC_EXPORT_SUBDIR", "export"),
        help="Subdirectory inside the checkout used for exported content.",
    )
    parser.add_argument(
        "--token-name",
        default=env_or("TRILIUM_GIT_SYNC_TOKEN_NAME", f"trilium-git-sync@{socket.gethostname()}"),
        help="Token name used when minting an API token from a password.",
    )
    parser.add_argument(
        "--mint-token",
        action="store_true",
        help="Interactively ask for the Trilium password and cache an API token, then exit.",
    )
    parser.add_argument(
        "--use-lfs",
        action="store_true",
        default=env_flag("TRILIUM_GIT_SYNC_USE_LFS", False),
        help="Track detected binary exported files with Git LFS using per-directory .gitattributes files.",
    )
    parser.add_argument(
        "--fix-gitattributes",
        action="store_true",
        help="Rewrite all .gitattributes files in the repo with correct escaping, commit, and exit.",
    )
    parser.add_argument(
        "--full-export",
        action="store_true",
        help="Force a complete re-export from Trilium, replacing all repo content. Use to heal a broken repo.",
    )
    parser.add_argument(
        "--reset",
        metavar="COMMIT",
        default=None,
        help="Reset Trilium to match a specific git commit. Deletes all notes under root and re-imports from that commit.",
    )
    parser.add_argument(
        "--home-dir",
        default=env_or("TRILIUM_GIT_SYNC_HOME_DIR"),
        help="Home directory for resolving file:// links. Defaults to $HOME. "
             "file:// links under this directory are committed to the repo under a 'home' folder.",
    )
    return parser.parse_args()


def load_config() -> SyncConfig:
    args = parse_args()
    return SyncConfig(
        base_url=args.base_url,
        root_note_id=args.root_note_id,
        repo_path=resolve_path(args.repo_path),
        worktree_root=resolve_path(args.worktree_root),
        remote_url=args.remote_url,
        branch=args.branch,
        state_dir=resolve_path(args.state_dir),
        export_subdir=args.export_subdir,
        token_name=args.token_name,
        mint_token=args.mint_token,
        use_lfs=args.use_lfs,
        fix_gitattributes=args.fix_gitattributes,
        full_export=args.full_export,
        reset_commit=args.reset,
        home_dir=resolve_path(args.home_dir) if args.home_dir else Path.home(),
        executable_name=Path(sys.argv[0]).name or "trilium-git-sync",
    )
