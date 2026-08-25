"""Git export workflow: sparse checkout, section commit, push/fetch, and diff.

Coordinates the sparse-checkout-based export commit strategy, upstream
fetch/push, and change diffing between revisions.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
from pathlib import Path, PurePosixPath

from git import GitCommandError, Repo

from .common import ensure_dir, log, posix_join, META_FILE_NAME
from .git_lfs import (
    ensure_git_lfs,
    sync_lfs_attributes,
)
from .git_repo import current_branch, current_head, has_commits, ref_exists


# ---------------------------------------------------------------------------
# Sparse checkout helpers
# ---------------------------------------------------------------------------

def escape_sparse_pattern_component(value: str) -> str:
    return "".join("\\" + char if char in {"\\", "*", "?", "[", "]", "!"} else char for char in value)


def has_changes(checkout: Path, path: str) -> bool:
    repo = Repo(str(checkout))
    return bool(repo.git.status("--porcelain", "--", f":(literal){path}"))


def collect_directory_file_map(root_dir: Path, restricted_dirs: set[str] | None = None) -> dict[str, set[str]]:
    mapping: dict[str, set[str]] = {}
    if not root_dir.exists():
        return mapping
    if restricted_dirs is None:
        for directory, _, files in os.walk(root_dir):
            rel_dir = Path(directory).relative_to(root_dir).as_posix()
            mapping.setdefault("" if rel_dir == "." else rel_dir, set()).update(sorted(files))
        return mapping

    for rel_dir in sorted(restricted_dirs):
        dir_path = root_dir if rel_dir == "" else root_dir / rel_dir
        mapping[rel_dir] = set() if not dir_path.is_dir() else {
            child.name for child in dir_path.iterdir() if child.is_file() or child.is_symlink()
        }
    return mapping


def tracked_directory_file_map(checkout: Path, export_subdir: str, restricted_dirs: set[str] | None = None) -> dict[str, set[str]]:
    mapping: dict[str, set[str]] = {}
    if not has_commits(checkout):
        return mapping

    repo = Repo(str(checkout))
    try:
        output = repo.git.ls_tree("-r", "-z", "--name-only", "HEAD", "--", f":(literal){export_subdir}")
    except GitCommandError:
        return mapping

    export_root = PurePosixPath(export_subdir)
    restricted = set(restricted_dirs) if restricted_dirs is not None else None
    for raw_path in output.split("\0"):
        if not raw_path:
            continue
        rel_path = PurePosixPath(raw_path).relative_to(export_root).as_posix()
        rel_parent = str(PurePosixPath(rel_path).parent)
        rel_parent = "" if rel_parent == "." else rel_parent
        if restricted is None or rel_parent in restricted:
            mapping.setdefault(rel_parent, set()).add(PurePosixPath(rel_path).name)

    if restricted is not None:
        for rel_dir in restricted:
            mapping.setdefault(rel_dir, set())
    return mapping


def section_order(section_dirs: set[str]) -> list[str]:
    return sorted(section_dirs, key=lambda item: (-PurePosixPath(item).as_posix().count("/"), item))


def build_sparse_patterns(section_repo_dir: str, file_names: set[str]) -> list[str]:
    escaped_dir = "/".join(escape_sparse_pattern_component(part) for part in PurePosixPath(section_repo_dir).parts)
    return [
        f"/{escaped_dir}/",
        f"!/{escaped_dir}/*/",
        *[f"/{escaped_dir}/{escape_sparse_pattern_component(name)}" for name in sorted(file_names)],
    ]


def apply_sparse_patterns(worktree: Path, branch: str, patterns: list[str]) -> None:
    repo = Repo(str(worktree))
    repo.git.sparse_checkout("init", "--no-cone")
    sparse_path = Path(repo.git.rev_parse("--git-path", "info/sparse-checkout"))
    sparse_path.write_text("\n".join(patterns) + "\n")

    if has_commits(worktree):
        cur = current_branch(worktree)
        if cur != branch:
            if ref_exists(worktree, f"refs/heads/{branch}"):
                repo.git.checkout(branch)
            else:
                repo.git.checkout("-B", branch)
        else:
            repo.git.read_tree("-mu", "HEAD")
    elif current_branch(worktree) != branch:
        repo.git.checkout("-b", branch)


def sync_section_files(source_dir: Path, target_dir: Path, direct_files: set[str]) -> None:
    ensure_dir(target_dir)
    existing_files = {child.name for child in target_dir.iterdir() if child.is_file() or child.is_symlink()}
    for name in sorted(existing_files - direct_files):
        (target_dir / name).unlink()
    for name in sorted(direct_files):
        source_file = source_dir / name
        target_file = target_dir / name
        if not source_file.exists():
            if target_file.exists() or target_file.is_symlink():
                target_file.unlink()
            continue
        ensure_dir(target_file.parent)
        shutil.copy2(source_file, target_file)


# ---------------------------------------------------------------------------
# Export commit workflow
# ---------------------------------------------------------------------------

def commit_export(
    checkout: Path,
    branch: str,
    export_subdir: str,
    source_export_dir: Path,
    root_note_id: str,
    use_lfs: bool,
    affected_section_dirs: set[str] | None = None,
    commit_message: str | None = None,
) -> bool:
    if use_lfs:
        ensure_git_lfs(checkout)
    touched_lfs_dirs = sync_lfs_attributes(source_export_dir, use_lfs, restricted_dirs=affected_section_dirs)

    if affected_section_dirs is None:
        source_map = collect_directory_file_map(source_export_dir)
        tracked_map = tracked_directory_file_map(checkout, export_subdir)
        section_dirs = {d for d, files in source_map.items() if files} | {d for d, files in tracked_map.items() if files}
    else:
        section_dirs = set(affected_section_dirs) | touched_lfs_dirs
        source_map = collect_directory_file_map(source_export_dir, section_dirs)
        tracked_map = tracked_directory_file_map(checkout, export_subdir, section_dirs)

    if not section_dirs:
        log(f"no export sections found under {source_export_dir}")
        return False

    squash_base = current_head(checkout)
    temp_base_created = False
    section_commit_count = 0
    ordered_sections = section_order(section_dirs)
    log(f"processing {len(ordered_sections)} sparse export sections under {export_subdir}")

    repo = Repo(str(checkout))
    for index, rel_dir in enumerate(ordered_sections, start=1):
        direct_files = set(source_map.get(rel_dir, set()))
        tracked_files = set(tracked_map.get(rel_dir, set()))
        materialized_files = direct_files | tracked_files
        if not materialized_files:
            continue

        section_repo_dir = posix_join(export_subdir, rel_dir)
        log(f"processing sparse export section {index}/{len(ordered_sections)}: {section_repo_dir}")
        apply_sparse_patterns(checkout, branch, build_sparse_patterns(section_repo_dir, materialized_files))
        sync_section_files(source_export_dir if rel_dir == "" else source_export_dir / rel_dir, checkout / section_repo_dir, direct_files)

        removed_files = tracked_files - direct_files
        if removed_files:
            rm_paths = [f":(literal){posix_join(section_repo_dir, name)}" for name in sorted(removed_files)]
            repo.git.rm("--sparse", "-f", "--ignore-unmatch", "--", *rm_paths)
        repo.git.add("--sparse", "-A")
        if not has_changes(checkout, section_repo_dir):
            continue

        if squash_base is None and not temp_base_created:
            repo.git.commit("--allow-empty", "-m", "trilium-git-sync: temporary sparse export base")
            squash_base = current_head(checkout)
            temp_base_created = True

        try:
            repo.git.commit("-m", f"trilium-git-sync: export section {section_repo_dir}")
        except GitCommandError as exc:
            if "nothing to commit" in (exc.stdout or ""):
                continue
            raise
        section_commit_count += 1
        log(f"committed sparse export section {section_repo_dir}")

    # Stage repo-root README.md if present (generated by TOC)
    # Copy from source dir (README lives alongside export_subdir in temp)
    readme_changed = False
    source_readme = source_export_dir.parent / "README.md"
    if source_readme.exists():
        import shutil as _shutil
        dest_readme = checkout / "README.md"
        _shutil.copy2(source_readme, dest_readme)
        repo.git.add("--sparse", "README.md")
        # Check if README actually has staged changes
        try:
            repo.git.diff("--cached", "--quiet", "--", "README.md")
        except Exception:
            readme_changed = True

    if section_commit_count == 0 and not readme_changed:
        log(f"no export changes detected under {export_subdir}")
        return False

    # If only README changed (no section commits), create a base for squash
    if section_commit_count == 0 and readme_changed:
        if squash_base is None and not temp_base_created:
            repo.git.commit("--allow-empty", "-m", "trilium-git-sync: temporary sparse export base")
            squash_base = current_head(checkout)
            temp_base_created = True
        repo.git.commit("-m", "trilium-git-sync: README update")
        section_commit_count += 1

    # Finalize: squash all section commits into one
    if squash_base is None:
        raise RuntimeError("internal error: missing squash base for export commit")
    repo.git.reset("--soft", squash_base)
    message = commit_message or f"sync: export Trilium {root_note_id} from {socket.gethostname()}"
    if temp_base_created:
        repo.git.commit("--amend", "-m", message)
    else:
        repo.git.commit("-m", message)

    log(f"committed exported Trilium content for root note {root_note_id} via {section_commit_count} sparse sections")
    return True


# ---------------------------------------------------------------------------
# Push / fetch
# ---------------------------------------------------------------------------

def can_push_fast_forward(checkout: Path, branch: str, remote_name: str = "upstream") -> tuple[bool, str]:
    remote_ref = f"refs/remotes/{remote_name}/{branch}"
    if not ref_exists(checkout, remote_ref):
        return True, "remote branch missing"
    repo = Repo(str(checkout))
    local = repo.head.commit.hexsha
    remote = repo.git.rev_parse(remote_ref)
    if local == remote:
        return False, "already up to date"
    try:
        repo.git.merge_base("--is-ancestor", remote_ref, "HEAD")
        return True, "remote is ancestor of local"
    except GitCommandError:
        pass
    try:
        repo.git.merge_base("--is-ancestor", "HEAD", remote_ref)
        return False, "remote has new commits that would need import"
    except GitCommandError:
        pass
    return False, "local and remote have diverged"


def push_if_possible(checkout: Path, branch: str, remote_url: str | None) -> None:
    if not remote_url:
        log("remote URL not configured; skipping upstream push")
        return
    should_push, reason = can_push_fast_forward(checkout, branch)
    if not should_push:
        log(f"skipping upstream push: {reason}")
        return
    repo = Repo(str(checkout))
    if ref_exists(checkout, f"refs/remotes/upstream/{branch}"):
        log(f"pushing branch {branch} to upstream")
        repo.git.push("upstream", branch)
    else:
        log(f"pushing branch {branch} to upstream and setting upstream tracking")
        repo.git.push("-u", "upstream", branch)


# ---------------------------------------------------------------------------
# Fetch and diff helpers
# ---------------------------------------------------------------------------

def fetch_upstream(repo_path: Path, branch: str, remote_url: str | None) -> str | None:
    """Fetch upstream and return its HEAD sha. Returns None if no upstream."""
    if not remote_url:
        log("[pull] no remote configured → skip fetch")
        return None

    log(f"[pull] fetching upstream/{branch}")
    from .git_repo import _bare_repo
    repo = _bare_repo(repo_path)
    try:
        repo.git.fetch("upstream", branch)
    except GitCommandError as e:
        log(f"[pull] ⚠ fetch failed: {e.stderr.strip() if e.stderr else e}")
        return None

    try:
        return repo.git.rev_parse("--verify", f"refs/remotes/upstream/{branch}")
    except GitCommandError:
        return None


def has_export_at(worktree: Path, rev: str, export_subdir: str) -> bool:
    """Check if a specific revision has an export with !!!meta.json."""
    repo = Repo(str(worktree))
    try:
        repo.git.cat_file("-t", f"{rev}:{export_subdir}/{META_FILE_NAME}")
        return True
    except GitCommandError:
        return False


def get_sync_ids_at_rev(worktree: Path, rev: str | None, export_subdir: str) -> set[str]:
    """Read !!!meta.json at a revision and return all noteIds (syncIds)."""
    if not rev:
        return set()
    repo = Repo(str(worktree))
    try:
        content = repo.git.show(f"{rev}:{export_subdir}/{META_FILE_NAME}")
    except GitCommandError:
        return set()
    try:
        meta = json.loads(content)
    except (json.JSONDecodeError, ValueError):
        return set()

    ids: set[str] = set()
    def collect(entries: list) -> None:
        for entry in entries:
            nid = entry.get("noteId", "")
            if nid and nid != "root":
                ids.add(nid)
            if entry.get("children"):
                collect(entry["children"])
    collect(meta.get("files", []))
    return ids


def prepare_export_dir(worktree: Path, export_subdir: str, use_lfs: bool) -> Path | None:
    """Check out the export directory from git, smudge LFS, return path."""
    src = worktree / export_subdir
    repo = Repo(str(worktree))
    if not src.is_dir():
        try:
            repo.git.sparse_checkout("disable")
        except GitCommandError:
            pass
        try:
            repo.git.checkout("HEAD", "--", export_subdir)
        except GitCommandError:
            pass
    if not src.is_dir():
        log(f"[pull] ⚠ export subdir {export_subdir} not found")
        return None

    if use_lfs:
        from .git_lfs import lfs_pull_and_smudge
        lfs_pull_and_smudge(worktree, src)

    return src


def compute_diff(worktree: Path, old_head: str, new_head: str, export_subdir: str) -> list[dict]:
    """Compute file changes between two commits."""
    repo = Repo(str(worktree))
    try:
        output = repo.git.diff("--name-status", "-z", old_head, new_head, "--", export_subdir)
    except GitCommandError as e:
        log(f"[pull] ⚠ git diff failed: {e.stderr.strip() if e.stderr else e}")
        return []

    changes: list[dict] = []
    tokens = output.split("\0")
    if tokens and tokens[-1] == "":
        tokens.pop()

    i = 0
    while i < len(tokens):
        status = tokens[i]
        i += 1
        if not status:
            continue
        code = status[0]
        if code in {"R", "C"}:
            old_path, new_path = tokens[i], tokens[i + 1]
            i += 2
            changes.append({"action": "rename", "oldPath": old_path, "newPath": new_path, "path": new_path})
        else:
            path = tokens[i]
            i += 1
            changes.append({"action": {"A": "add", "D": "delete", "M": "modify"}.get(code, code), "path": path})

    return changes
