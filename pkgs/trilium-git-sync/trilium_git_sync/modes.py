"""One-shot command modes: full export, reset-to-commit, fix-gitattributes."""
from __future__ import annotations

import socket
from pathlib import PurePosixPath

from git import Repo as _GitRepo, GitCommandError as _GitError

from .apply import apply_full_import
from .client import TriliumClient
from .common import log, log_note_line, META_FILE_NAME
from .git_export import current_head, fetch_upstream, push_if_possible
from .git_lfs import (
    _write_lfs_entries,
    lfs_pull_and_smudge,
    sync_lfs_attributes,
)
from .git_repo import (
    run_git,
    sync_worktree_session,
)
from .home_links import rewrite_home_links_for_import



def full_export_mode(config, client: TriliumClient, do_full_export) -> int:
    """Force a complete re-export from Trilium, replacing all repo content."""
    try:
        root_check = client.get_note(config.root_note_id)
    except Exception:
        root_check = None
    if root_check is None:
        log("✗ cannot connect to Trilium or auth token missing")
        return 1

    with sync_worktree_session(config) as session:
        worktree, branch = session.worktree, session.branch

        upstream_head = fetch_upstream(config.repo_path, branch, config.remote_url)
        if upstream_head:
            run_git(worktree, "sparse-checkout", "disable", check=False)
            run_git(worktree, "checkout", "-f", branch, check=False)
            run_git(worktree, "reset", "--hard", upstream_head)

        log("[push] full export (forced)")
        do_full_export(client, worktree, branch, config,
                       commit_message=f"sync: full re-export from {socket.gethostname()}")

        push_if_possible(worktree, branch, config.remote_url)
        log(f"✓ full export complete HEAD={current_head(worktree)[:12] if current_head(worktree) else 'none'}")
        return 0


def reset_to_commit(config, client: TriliumClient) -> int:
    """Reset Trilium to match a specific git commit exactly.

    1. Fetch the remote to ensure the commit is available locally.
    2. Check out the specified commit's export directory.
    3. Delete all child notes under root in Trilium.
    4. Import the export from that commit into Trilium.
    """
    commit = config.reset_commit

    try:
        root_check = client.get_note(config.root_note_id)
    except Exception:
        root_check = None
    if root_check is None:
        log("✗ cannot connect to Trilium or auth token missing")
        return 1

    with sync_worktree_session(config) as session:
        worktree, branch = session.worktree, session.branch
        log(f"resetting Trilium to commit {commit}")

        # Fetch to ensure commit is reachable
        fetch_upstream(config.repo_path, branch, config.remote_url)

        # Verify the commit exists
        wt_repo = _GitRepo(str(worktree))
        try:
            obj_type = wt_repo.git.cat_file("-t", commit)
        except _GitError:
            obj_type = ""
        if obj_type.strip() != "commit":
            log(f"✗ '{commit}' is not a valid commit in this repo")
            return 1

        # Resolve to full sha
        full_sha = wt_repo.git.rev_parse(commit)
        log(f"[reset] target commit: {full_sha[:12]}")

        # Check out the target commit
        run_git(worktree, "sparse-checkout", "disable", check=False)
        run_git(worktree, "checkout", "-f", full_sha, check=False)

        # Verify export exists at that commit
        export_dir = worktree / config.export_subdir
        if not export_dir.is_dir() or not (export_dir / META_FILE_NAME).exists():
            log(f"✗ commit {full_sha[:12]} does not contain an export at '{config.export_subdir}/{META_FILE_NAME}'")
            return 1

        # Smudge LFS if needed
        if config.use_lfs:
            lfs_pull_and_smudge(worktree, export_dir)

        # Rewrite home links for import
        rewrite_home_links_for_import(export_dir, config.home_dir)

        # Delete all children under the root note
        log("[reset] deleting all notes under root...")
        _delete_all_children(client, config.root_note_id)
        log("[reset] ✓ Trilium cleared")

        # Import from the commit's export
        log(f"[reset] importing from {full_sha[:12]}...")
        apply_full_import(client, export_dir, config.root_note_id)

        # Restore root note content from the export's README.md
        # (apply_full_import skips root because it already exists).
        meta_path = export_dir / META_FILE_NAME
        if meta_path.exists():
            import json as _json
            _meta = _json.loads(meta_path.read_text())
            root_entry = next(
                (e for e in _meta.get("files", []) if e.get("noteId") == "root"),
                None,
            )
            root_data = root_entry.get("dataFileName") if root_entry else None
            if root_data:
                root_content_path = export_dir / root_data
                if root_content_path.exists():
                    content = root_content_path.read_text()
                    client.put_note_content(config.root_note_id, content)
                    log(f"[reset] ✓ restored root note content from {root_data}")

        log(f"✓ reset complete — Trilium now matches commit {full_sha[:12]}")

        # After reset, the repo branch still points at the old HEAD.
        # Do a full export on top of the target commit so the git repo
        # accurately reflects the (now-reset) Trilium state.  Without
        # this, the next normal sync would compute an incremental diff
        # against the stale branch HEAD, producing inconsistent results.
        from .sync import _do_export
        log("[push] re-exporting after reset")
        run_git(worktree, "checkout", "-B", branch, full_sha, check=False)
        _do_export(client, worktree, branch, config,
                   commit_message=f"sync: re-export after reset to {full_sha[:12]}")
        push_if_possible(worktree, branch, config.remote_url)
        log(f"✓ post-reset export complete HEAD={current_head(worktree)[:12] if current_head(worktree) else 'none'}")
        return 0


def _delete_all_children(client: TriliumClient, root_note_id: str) -> None:
    """Delete all child notes under the root, leaving the root itself intact but cleared."""
    root = client.get_note(root_note_id)
    if root is None:
        return

    # Clear root note content
    try:
        client.put_note_content(root_note_id, "")
        log("[reset]   cleared root note content")
    except Exception as e:
        log(f"[reset]   ⚠ failed to clear root content: {e}")

    child_note_ids = root.get("childNoteIds", [])
    if not child_note_ids:
        log("[reset]   no children to delete")
        return

    # Collect info and log all children, then delete
    children_info: list[tuple[str, str | None, str | None]] = []  # (id, syncId, title)
    for child_id in child_note_ids:
        child = client.get_note(child_id)
        title = child.get("title") if child else None
        sync_id = None
        if child:
            for attr in child.get("attributes", []):
                if attr.get("type") == "label" and attr.get("name") == "gitSyncId":
                    sync_id = attr.get("value")
                    break
        children_info.append((child_id, sync_id, title))

    log(f"[reset]   {len(children_info)} top-level children to delete:")
    for child_id, sync_id, title in children_info:
        log_note_line(child_id, sync_id, title)

    for child_id, sync_id, title in children_info:
        log("[reset]   deleting:")
        log_note_line(child_id, sync_id, title)
        try:
            client.delete_note(child_id)
        except Exception as e:
            log(f"[reset]   ⚠ failed to delete: {e}")
            log_note_line(child_id, sync_id, title)


def fix_all_gitattributes(config) -> int:
    """Rewrite all .gitattributes in the repo from actual file contents."""
    with sync_worktree_session(config, lock=False) as session:
        worktree, branch = session.worktree, session.branch
        repo = _GitRepo(str(worktree))
        repo.git.sparse_checkout("disable")
        repo.git.checkout(branch)
        export_dir = worktree / config.export_subdir
        if not export_dir.exists():
            log("[fix] no export directory found")
            return 1

        # Smudge LFS pointers
        lfs_pull_and_smudge(worktree, export_dir)

        # Get authoritative LFS file list
        lfs_files: set[str] = set()
        try:
            lfs_output = repo.git.lfs("ls-files", "--name-only")
            for line in lfs_output.splitlines():
                line = line.strip()
                if line:
                    lfs_files.add(line)
        except _GitError:
            pass
        log(f"[fix] git lfs reports {len(lfs_files)} tracked files")

        # Remove all existing .gitattributes
        removed = 0
        for attr_path in sorted(export_dir.rglob(".gitattributes")):
            attr_path.unlink()
            removed += 1

        # Rebuild from LFS file list
        export_subdir_prefix = config.export_subdir + "/"
        dirs_to_entries: dict[str, set[str]] = {}
        for rel_path in sorted(lfs_files):
            if rel_path.startswith(export_subdir_prefix):
                rel_path = rel_path[len(export_subdir_prefix):]
            elif not (export_dir / rel_path).exists():
                continue
            p = PurePosixPath(rel_path)
            parent = str(p.parent) if str(p.parent) != "." else ""
            dirs_to_entries.setdefault(parent, set()).add(p.name)

        for rel_dir, names in sorted(dirs_to_entries.items()):
            dir_path = export_dir / rel_dir if rel_dir else export_dir
            attr_path = dir_path / ".gitattributes"
            _write_lfs_entries(attr_path, names)

        # Also scan for binary/large files not already in LFS
        touched = sync_lfs_attributes(export_dir, True)
        log(f"[fix] removed {removed} old .gitattributes, rebuilt {len(dirs_to_entries)} directories (+{len(touched)} from scan)")

        if repo.git.status("--porcelain").strip():
            log("[fix] committing .gitattributes changes...")
            repo.git.add("-A")
            repo.git.commit("-m", "fix: rebuild .gitattributes from actual file contents")
            push_if_possible(worktree, branch, config.remote_url)
            log(f"[fix] ✓ done, HEAD={current_head(worktree)[:12]}")
        else:
            log("[fix] no changes needed")
        return 0
