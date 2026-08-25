"""Git repo discovery, bootstrap, worktree lifecycle, identity, and remote config."""
from __future__ import annotations

import shutil
import socket
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Generator

import git as _git
from git import GitCommandError, InvalidGitRepositoryError, Repo

from .common import ensure_dir, log


# Cache of worktree path → Repo instance to avoid repeated re-opens
_repo_cache: dict[str, Repo] = {}


# ---------------------------------------------------------------------------
# Repo discovery / status helpers
# ---------------------------------------------------------------------------

def _bare_repo(repo_path: Path) -> Repo:
    """Open a bare repo with --git-dir on the command line for all git calls."""
    repo = Repo(str(repo_path))
    # Always pass --git-dir explicitly on the command line,
    # since cwd-based detection can fail in some environments.
    repo.git.set_persistent_git_options(git_dir=str(repo_path))
    return repo


def open_repo(path: Path) -> Repo | None:
    """Open an existing git repo (bare or non-bare). Returns None if invalid."""
    try:
        return Repo(str(path))
    except (InvalidGitRepositoryError, _git.NoSuchPathError):
        return None


def has_commits(path: Path, repo: Repo | None = None) -> bool:
    repo = repo or open_repo(path)
    if repo is None:
        return False
    try:
        repo.head.commit
        return True
    except Exception:
        return False


def ref_exists(checkout: Path, ref: str, repo: Repo | None = None) -> bool:
    repo = repo or open_repo(checkout)
    if repo is None:
        return False
    try:
        repo.git.show_ref("--verify", "--quiet", ref)
        return True
    except GitCommandError:
        return False


def current_branch(checkout: Path, repo: Repo | None = None) -> str | None:
    repo = repo or open_repo(checkout)
    if repo is None:
        return None
    try:
        return repo.active_branch.name
    except TypeError:
        return None


def current_head(checkout: Path, repo: Repo | None = None) -> str | None:
    repo = repo or open_repo(checkout)
    if repo is None:
        return None
    try:
        return repo.head.commit.hexsha
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

def bootstrap_bare_repo(repo_path: Path, remote_url: str | None, branch: str | None) -> bool:
    """Bootstrap a bare git repo. Returns True if a fresh clone/init was performed."""
    if open_repo(repo_path) is not None:
        log(f"using existing bare repo at {repo_path}")
        return False
    if repo_path.exists() and not repo_path.is_dir():
        raise RuntimeError(f"Repo path is not a directory: {repo_path}")
    if not repo_path.exists() or (repo_path.is_dir() and not any(repo_path.iterdir())):
        pass  # empty or non-existent — proceed
    elif repo_path.is_dir() and any(repo_path.iterdir()):
        raise RuntimeError(f"Repo path is not empty and is not a git repo: {repo_path}")

    ensure_dir(repo_path.parent)
    if remote_url:
        log(f"cloning bare repo from remote into {repo_path}")
        kwargs: dict = {"bare": True}
        if branch:
            kwargs["branch"] = branch
            kwargs["single_branch"] = True
        Repo.clone_from(remote_url, str(repo_path), **kwargs)
        return True

    log(f"initializing bare git repo at {repo_path}")
    repo = Repo.init(str(repo_path), bare=True)
    if branch:
        repo.git.symbolic_ref("HEAD", f"refs/heads/{branch}")
    return True


# ---------------------------------------------------------------------------
# Worktree management
# ---------------------------------------------------------------------------

def remove_temp_worktree(repo_path: Path, worktree: Path) -> None:
    repo = _bare_repo(repo_path)
    try:
        repo.git.worktree("remove", "--force", str(worktree))
    except GitCommandError:
        pass
    try:
        repo.git.worktree("prune")
    except GitCommandError:
        pass
    if worktree.exists():
        shutil.rmtree(worktree, ignore_errors=True)


def cleanup_managed_worktrees(repo_path: Path, worktree_root: Path) -> None:
    ensure_dir(worktree_root)
    repo = _bare_repo(repo_path)
    try:
        repo.git.worktree("prune")
    except GitCommandError:
        pass

    # Find worktrees managed under worktree_root
    repo_resolved = repo_path.resolve()
    root = worktree_root.resolve()
    try:
        output = repo.git.worktree("list", "--porcelain")
    except GitCommandError:
        output = ""
    for line in output.splitlines():
        if not line.startswith("worktree "):
            continue
        candidate = Path(line[len("worktree "):]).resolve()
        if candidate == repo_resolved:
            continue
        try:
            candidate.relative_to(root)
        except ValueError:
            continue
        log(f"removing stale managed temporary worktree {candidate}")
        remove_temp_worktree(repo_path, candidate)

    for child in sorted(worktree_root.iterdir()):
        if child.name.startswith("worktree-"):
            shutil.rmtree(child, ignore_errors=True)


def create_temp_worktree(repo_path: Path, worktree_root: Path, branch: str | None) -> Path:
    cleanup_managed_worktrees(repo_path, worktree_root)
    worktree = Path(tempfile.mkdtemp(prefix="worktree-", dir=worktree_root))

    def _repo_head_branch() -> str | None:
        r = open_repo(repo_path)
        if r is None:
            return None
        try:
            return r.head.reference.name
        except TypeError:
            return None

    target_branch = branch or _repo_head_branch() or "main"
    log(f"creating temporary worktree at {worktree} from {repo_path} on branch {target_branch}")

    repo = _bare_repo(repo_path)
    if has_commits(repo_path, repo=repo):
        if ref_exists(repo_path, f"refs/heads/{target_branch}", repo=repo):
            repo.git.worktree("add", "--force", "--no-checkout", str(worktree), target_branch)
        else:
            repo.git.worktree("add", "--force", "--no-checkout", "-b", target_branch, str(worktree))
    else:
        repo.git.worktree("add", "-b", target_branch, str(worktree))
    return worktree


# ---------------------------------------------------------------------------
# Remote / identity
# ---------------------------------------------------------------------------

def ensure_upstream_remote(repo_path: Path, remote_url: str | None) -> None:
    if not remote_url:
        log("no upstream git remote configured; fetch/push will be skipped")
        return

    repo = _bare_repo(repo_path)
    remotes = {r.name for r in repo.remotes}
    if "upstream" in remotes:
        current_url = repo.remotes["upstream"].url
        if current_url == remote_url:
            log("confirmed git remote upstream URL matches configured remote")
        else:
            repo.git.remote("set-url", "upstream", remote_url)
            log("updated git remote upstream URL to match configured remote")
    else:
        repo.git.remote("add", "upstream", remote_url)
        log("added git remote upstream")


def run_git(worktree: Path, *args: str, check: bool = True) -> str:
    """Run a git command in the worktree via GitPython. Returns stdout.

    Uses a per-worktree Repo cache to avoid repeated re-opens.
    """
    key = str(worktree)
    repo = _repo_cache.get(key)
    if repo is None:
        repo = Repo(key)
        _repo_cache[key] = repo
    cmd = args[0].replace("-", "_") if args else ""
    rest = list(args[1:])
    try:
        return getattr(repo.git, cmd)(*rest)
    except GitCommandError as e:
        if check:
            raise RuntimeError(f"git {args[0]} failed: {e.stderr}") from e
        return e.stdout or ""


def invalidate_repo_cache(worktree: Path) -> None:
    """Remove a worktree from the repo cache (call before deletion)."""
    _repo_cache.pop(str(worktree), None)


def ensure_identity(checkout: Path) -> None:
    repo = Repo(str(checkout))
    try:
        name = repo.config_reader().get_value("user", "name")
    except Exception:
        name = None
    try:
        email = repo.config_reader().get_value("user", "email")
    except Exception:
        email = None

    with repo.config_writer() as cw:
        if not name:
            cw.set_value("user", "name", "Trilium Git Sync")
        if not email:
            cw.set_value("user", "email", f"trilium-git-sync@{socket.gethostname()}")


# ---------------------------------------------------------------------------
# Session context manager
# ---------------------------------------------------------------------------

@dataclass
class SyncSession:
    """State yielded by sync_worktree_session."""
    worktree: Path
    branch: str
    fresh_clone: bool


@contextmanager
def sync_worktree_session(config, *, lock: bool = True) -> Generator[SyncSession, None, None]:
    """Acquire lock, bootstrap bare repo, create worktree, ensure identity.

    Yields a SyncSession with the ready worktree.  Cleans up the worktree on exit.
    Use ``lock=False`` for operations that manage their own locking.
    """
    from .common import Lock

    ctx = Lock(config.state_dir / "sync.lock") if lock else None
    if ctx:
        ctx.__enter__()
        log("lock acquired")
    try:
        fresh_clone = bootstrap_bare_repo(config.repo_path, config.remote_url, config.branch)
        ensure_upstream_remote(config.repo_path, config.remote_url)

        branch = config.branch or "main"
        worktree = create_temp_worktree(config.repo_path, config.worktree_root, branch)
        try:
            ensure_identity(worktree)
            yield SyncSession(worktree=worktree, branch=branch, fresh_clone=fresh_clone)
        finally:
            invalidate_repo_cache(worktree)
            remove_temp_worktree(config.repo_path, worktree)
            log("worktree cleaned up")
    finally:
        if ctx:
            ctx.__exit__(None, None, None)
