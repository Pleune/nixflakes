"""Sync orchestrator: the main sync loop and mode dispatch.

Coordinates git operations, Trilium API calls, export, import, and rewriting
into a coherent bidirectional sync cycle.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import tempfile
from pathlib import Path

from .apply import apply_full_import, apply_pull_plan, tag_note_with_sync_id
from .cli import load_config
from .client import TriliumClient
from .common import ensure_dir, ensure_private_dir, format_note_line, log, log_note_line, log_note_lines, META_FILE_NAME
from .export import (
    extract_export,
    pretty_format_export_json_files,
    remove_note_from_export,
    apply_export_move,
    _generate_toc,
)
from .meta_tree import (
    find_entry_by_sync_id as _find_entry_in_meta,
    find_entry_by_sync_id,
    find_note_path_in_meta,
    insert_entry_into_meta,
    splice_meta_entry,
)
from .git_repo import (
    current_head,
    run_git,
    sync_worktree_session,
)
from .git_lfs import (
    smudge_lfs_pointers,
)
from .git_export import (
    commit_export,
    compute_diff,
    fetch_upstream,
    get_sync_ids_at_rev,
    has_export_at,
    prepare_export_dir,
    push_if_possible,
)
from .manifest import (
    build_git_manifest,
    build_id_map,
    build_pull_plan,
    build_trilium_manifest,
    detect_export_moves,
    detect_local_deletions,
    find_changed_notes_since,
    find_topmost_roots,
)
from .rewrite_ids import (
    generate_clone_pointer_files,
    inject_clone_parent_ids,
    rewrite_ids_in_content,
    rewrite_ids_in_entries,
    strip_clone_stubs,
)
from .home_links import (
    rewrite_home_links_for_export,
    rewrite_home_links_for_import,
    stage_home_files_post_commit,
)


def main() -> int:
    config = load_config()
    ensure_private_dir(config.state_dir)

    log(
        f"starting sync run base_url={config.base_url} repo_path={config.repo_path} "
        f"worktree_root={config.worktree_root} state_dir={config.state_dir} "
        f"branch={config.branch or '<auto>'} export_subdir={config.export_subdir} use_lfs={config.use_lfs}"
    )

    if config.use_lfs and not os.environ.get("GIT_LFS_SKIP_SMUDGE"):
        os.environ["GIT_LFS_SKIP_SMUDGE"] = "1"
        log("[lfs] skip-smudge enabled")

    client = TriliumClient(config.base_url, config.state_dir, config.token_name, executable_name=config.executable_name)
    if config.mint_token:
        log("[auth] minting API token")
        client.mint_token_interactive()
        log(f"[auth] ✓ token cached at {client.cached_token_path}")
        return 0

    if config.fix_gitattributes:
        from .modes import fix_all_gitattributes
        return fix_all_gitattributes(config)

    if config.reset_commit:
        from .modes import reset_to_commit
        return reset_to_commit(config, client)

    if config.full_export:
        from .modes import full_export_mode
        return full_export_mode(config, client, _do_export)

    # Pre-flight: verify Trilium auth
    try:
        root_check = client.get_note(config.root_note_id)
    except Exception:
        root_check = None
    if root_check is None:
        log(f"✗ cannot connect to Trilium or auth token missing")
        log(f"  token path: {client.cached_token_path}")
        log(f"  mint with: {config.executable_name} --mint-token")
        return 1

    with sync_worktree_session(config) as session:
        worktree, branch, fresh_clone = session.worktree, session.branch, session.fresh_clone

        # ─── Step 1: Note current local HEAD ───
        local_head = current_head(worktree)
        log(f"local={local_head[:12] if local_head else 'none'}")

        previously_exported_sync_ids = get_sync_ids_at_rev(worktree, local_head, config.export_subdir)

        # ─── Step 2: FETCH upstream ───
        upstream_head = fetch_upstream(config.repo_path, branch, config.remote_url)
        log(f"upstream={upstream_head[:12] if upstream_head else 'none'}")

        has_upstream_changes = (
            upstream_head is not None
            and upstream_head != local_head
        )

        # ─── Step 3: Handle fresh clone / no local state ───
        if fresh_clone and upstream_head:
            log("[pull] fresh clone → full import")
            _git(worktree, "sparse-checkout", "disable", check=False)
            _git(worktree, "checkout", "-f", branch)
            export_dir = prepare_export_dir(worktree, config.export_subdir, config.use_lfs)
            if export_dir:
                rewrite_home_links_for_import(export_dir, config.home_dir)
                apply_full_import(client, export_dir, config.root_note_id)
            # After import, reset and do a full export on top.
            _git(worktree, "reset", "--hard", upstream_head)
            _do_export(client, worktree, branch, config)
            push_if_possible(worktree, branch, config.remote_url)
            log(f"✓ sync complete HEAD={current_head(worktree)[:12] if current_head(worktree) else 'none'}")
            return 0

        if not local_head and not upstream_head:
            log("[push] no commits → initial export")
            _do_export(client, worktree, branch, config)
            push_if_possible(worktree, branch, config.remote_url)
            log(f"✓ sync complete HEAD={current_head(worktree)[:12] if current_head(worktree) else 'none'}")
            return 0

        if has_upstream_changes and (not local_head or not has_export_at(worktree, local_head, config.export_subdir)):
            log("[pull] no local export state → full import then export")
            _git(worktree, "sparse-checkout", "disable", check=False)
            _git(worktree, "checkout", "-f", branch, check=False)
            _git(worktree, "reset", "--hard", upstream_head)
            export_dir = prepare_export_dir(worktree, config.export_subdir, config.use_lfs)
            if export_dir:
                rewrite_home_links_for_import(export_dir, config.home_dir)
                apply_full_import(client, export_dir, config.root_note_id)
            _do_export(client, worktree, branch, config)
            push_if_possible(worktree, branch, config.remote_url)
            log(f"✓ sync complete HEAD={current_head(worktree)[:12] if current_head(worktree) else 'none'}")
            return 0

        # ─── Step 4: EXPORT from Trilium (onto local HEAD) ───
        locally_deleted = detect_local_deletions(
            client, previously_exported_sync_ids, config.root_note_id
        )

        changed_note_ids = find_changed_notes_since(
            client, worktree, local_head, config.root_note_id,
            previously_exported_sync_ids,
        )

        # Quick move check.
        has_moves = False
        if changed_note_ids is not None and not changed_note_ids and not locally_deleted:
            export_dir = worktree / config.export_subdir
            if export_dir.is_dir():
                meta_path = export_dir / "!!!meta.json"
                if meta_path.exists():
                    _meta = json.loads(meta_path.read_text())
                    _tm = build_trilium_manifest(client, config.root_note_id)
                    _id_map = build_id_map(_tm["notesByTriliumId"])
                    has_moves = bool(detect_export_moves(_meta, _tm, _id_map, config.root_note_id))

        export_sha: str | None = None
        if changed_note_ids is None:
            log("[push] full export (no prior commit)")
            export_sha = _do_export(client, worktree, branch, config)
        elif changed_note_ids or locally_deleted or has_moves:
            if changed_note_ids:
                if changed_note_ids == [config.root_note_id]:
                    log("[push] root note changed → full export")
                else:
                    log(f"[push] {len(changed_note_ids)} notes changed → incremental export")
            if locally_deleted:
                log(f"[push] {len(locally_deleted)} notes deleted locally → removing from git")
            if has_moves:
                log("[push] moves detected → incremental export")
            export_sha = _do_export(
                client, worktree, branch, config,
                changed_note_ids=changed_note_ids or [],
                locally_deleted=locally_deleted,
                previously_exported_sync_ids=previously_exported_sync_ids,
            )
        else:
            log("[push] no local changes since last commit")

        # ─── Step 5: INTEGRATE upstream changes ───
        if has_upstream_changes:
            if export_sha and export_sha != local_head:
                # Both sides have changes → cherry-pick merge.
                log(f"[sync] integrating: local export {export_sha[:12]} + upstream {upstream_head[:12]}")
                _integrate_with_upstream(
                    client, worktree, branch, config,
                    local_head, upstream_head, export_sha,
                )
            else:
                # Only upstream changes → straight pull.
                log(f"[pull] diff {local_head[:12]}..{upstream_head[:12]}")
                _apply_upstream_changes(
                    client, worktree, local_head, upstream_head,
                    config.export_subdir, config.use_lfs, config.root_note_id,
                    home_dir=config.home_dir,
                )
        elif upstream_head and upstream_head == local_head and not export_sha:
            log("[sync] up to date")

        # ─── Step 6: PUSH ───
        push_if_possible(worktree, branch, config.remote_url)

        log(f"✓ sync complete HEAD={current_head(worktree)[:12] if current_head(worktree) else 'none'}")
        return 0


# ---------------------------------------------------------------------------
# Pull: apply upstream changes
# ---------------------------------------------------------------------------

def _apply_upstream_changes(
    client: TriliumClient, worktree: Path, local_head: str, upstream_head: str,
    export_subdir: str, use_lfs: bool, root_note_id: str,
    home_dir: Path | None = None,
) -> None:
    """Diff local vs upstream and apply changes to Trilium."""
    _git(worktree, "reset", "--hard", upstream_head)
    export_dir = prepare_export_dir(worktree, export_subdir, use_lfs)
    if not export_dir:
        log("[pull] ⚠ could not prepare export dir")
        return

    rewrite_home_links_for_import(export_dir, home_dir)

    changes = compute_diff(worktree, local_head, upstream_head, export_subdir)
    if not changes:
        log("[pull] no file changes in diff")
        return

    log(f"[pull] diff: {len(changes)} files changed")

    git_manifest = build_git_manifest(export_dir)
    trilium_manifest = build_trilium_manifest(client, root_note_id)

    changed_paths = set()
    for c in changes:
        if c.get("path"):
            p = c["path"]
            prefix = export_subdir + "/"
            if p.startswith(prefix):
                p = p[len(prefix):]
            changed_paths.add(p)
        if c.get("oldPath"):
            p = c["oldPath"]
            prefix = export_subdir + "/"
            if p.startswith(prefix):
                p = p[len(prefix):]
            changed_paths.add(p)

    _log_changed_paths_as_notes(changed_paths, git_manifest, trilium_manifest)

    # Parse the upstream commit timestamp for staleness comparison.
    from datetime import datetime, timezone
    from git import Repo as _PullRepo
    commit_time = None
    try:
        ts = _PullRepo(str(worktree)).git.log("-1", "--format=%aI", upstream_head)
        if ts.strip():
            commit_time = datetime.fromisoformat(ts.strip())
    except Exception:
        pass

    plan = build_pull_plan(git_manifest, trilium_manifest, export_dir, changed_paths, commit_time=commit_time, root_note_id=root_note_id)
    total = sum(plan["summary"].values())
    if total > 0:
        log(f"[pull] plan: {plan['summary']}")
        apply_pull_plan(client, plan, export_dir, git_manifest, trilium_manifest, root_note_id)
    else:
        log("[pull] nothing to apply")


# ---------------------------------------------------------------------------
# Push: export from Trilium to git
# ---------------------------------------------------------------------------

def _do_export(
    client: TriliumClient,
    worktree: Path,
    branch: str,
    config,
    *,
    changed_note_ids: list[str] | None = None,
    locally_deleted: list[str] | None = None,
    previously_exported_sync_ids: set[str] | None = None,
    commit_message: str | None = None,
) -> str | None:
    """Unified export: full or incremental depending on changed notes.

    Returns the commit SHA if changes were committed, or None if nothing changed.

    When ``changed_note_ids`` is None the entire Trilium tree is exported
    from scratch ("full export").

    When ``changed_note_ids`` is a list, only the minimal set of subtrees
    covering those notes is re-exported and merged into the existing git
    state ("incremental export"). If the root note itself is in the changed
    set, ``find_topmost_roots`` naturally collapses the list to ``[root]``
    whose subtree zip IS the whole tree — so it becomes a full export
    without special-casing.

    Phases:
        0. Bootstrap: build Trilium manifest and ID map.
        1. Moves: detect and apply parent changes (skipped for full).
        2. Subtrees: export each root subtree, merge files and meta.
        3. Deletions: remove locally-deleted notes (skipped for full).
        4. Meta finalization: clones, stubs, pointer files.
        5. Commit: format, home-link rewrite, TOC, sparse commit.
    """
    is_full = changed_note_ids is None
    changed_note_ids = changed_note_ids or []

    # --- Roots ---
    roots = (
        [config.root_note_id]
        if is_full
        else find_topmost_roots(client, changed_note_ids) if changed_note_ids else []
    )
    # When root_note_id is in the changed set, find_topmost_roots shadows
    # all children so roots collapses to [root_note_id] automatically.
    # Flag this so we can skip moves/deletes and diff all sections.
    is_root_export = roots == [config.root_note_id]

    # Track touched directories for sparse commit (None → diff all).
    affected_dirs: set[str] | None = None if is_root_export else {""}

    export_dir = worktree / config.export_subdir

    # Ensure we have an export dir to mutate (checkout from HEAD if needed).
    if not is_full:
        if not export_dir.is_dir():
            _git(worktree, "checkout", "HEAD", "--", config.export_subdir, check=False)
        if not export_dir.is_dir():
            log("[push] ⚠ no existing export → full export")
            is_full = True
            is_root_export = True
            roots = [config.root_note_id]
            affected_dirs = None

    # Load existing global meta (or start fresh for full exports).
    global_meta_path = export_dir / META_FILE_NAME
    if not is_full and not global_meta_path.exists():
        log("[push] ⚠ no existing meta → full export")
        is_full = True
        is_root_export = True
        roots = [config.root_note_id]
        affected_dirs = None
    global_meta = (
        json.loads(global_meta_path.read_text())
        if not is_full and global_meta_path.exists()
        else {"formatVersion": 2, "files": []}
    )

    # --- Phase 0: Bootstrap ---
    trilium_manifest = build_trilium_manifest(client, config.root_note_id)
    notes_by_id = trilium_manifest["notesByTriliumId"]
    id_map = _tag_and_build_id_map(client, trilium_manifest, config.root_note_id)

    if roots:
        kind = "full" if is_root_export else "incremental"
        log(f"[push] {kind}: {len(roots)} subtree(s):")
        for root_id in roots:
            entry = notes_by_id.get(root_id, {})
            log_note_line(root_id, id_map.get(root_id), entry.get("title"))

    # Classify changed notes for the commit message.
    prev_sync = previously_exported_sync_ids or set()
    created_notes: list[dict] = []
    updated_notes: list[dict] = []
    for nid in changed_note_ids:
        entry = notes_by_id.get(nid, {})
        sid = id_map.get(nid)
        descriptor = {
            "triliumId": nid,
            "syncId": sid,
            "title": entry.get("title"),
        }
        (updated_notes if sid and sid in prev_sync else created_notes).append(descriptor)

    if changed_note_ids:
        log(f"[push] {len(changed_note_ids)} note(s) changed:")
        for nid in changed_note_ids:
            entry = notes_by_id.get(nid, {})
            log_note_line(nid, id_map.get(nid), entry.get("title"))
    deleted_notes: list[dict] = []
    if locally_deleted:
        log(f"[push] {len(locally_deleted)} note(s) deleted locally:")
        for sync_id in locally_deleted:
            entry = _find_entry_in_meta(global_meta, sync_id)
            title = entry.get("title") if entry else None
            deleted_notes.append({"triliumId": None, "syncId": sync_id, "title": title})
            log_note_line(None, sync_id, title)

    # --- Phase 1: Moves (incremental only) ---
    moved_notes: list[dict] = []
    if not is_root_export:
        moved_notes = _apply_incremental_moves(
            client, export_dir, global_meta, trilium_manifest, id_map,
            config.root_note_id, affected_dirs,
        )

    # --- Phase 2: Export changed subtrees ---
    _export_subtrees(
        client, roots, export_dir, global_meta, trilium_manifest,
        notes_by_id, id_map, affected_dirs, config.root_note_id,
    )

    # --- Phase 3: Deletions (incremental only) ---
    if not is_root_export and locally_deleted:
        for del_sync_id in locally_deleted:
            del_loc = find_note_path_in_meta(global_meta, del_sync_id)
            del_entry = find_entry_by_sync_id(global_meta, del_sync_id)
            if del_loc and affected_dirs is not None:
                _record_entry_affected_dirs(affected_dirs, del_loc[0], del_entry)
            remove_note_from_export(export_dir, global_meta, del_sync_id)

    # --- Phase 4: Finalize meta ---
    _finalize_meta_clones(export_dir, global_meta, global_meta_path, notes_by_id, id_map,
                          affected_dirs=affected_dirs)

    # --- Phase 5: Commit ---
    if commit_message is None:
        # Detect moves for commit message even for root exports (full
        # exports don't run Phase 1 but we still want the summary).
        if is_root_export and not moved_notes:
            moved_notes = detect_export_moves(
                global_meta, trilium_manifest, id_map, config.root_note_id
            )
        commit_message = _build_incremental_commit_message(
            config,
            created=created_notes,
            updated=updated_notes,
            deleted=deleted_notes,
            moved=moved_notes,
            affected_dirs=affected_dirs,
        )
    _commit_export(
        worktree, branch, export_dir, config,
        affected_dirs=affected_dirs,
        commit_message=commit_message,
    )
    return current_head(worktree)


def _tag_and_build_id_map(
    client: TriliumClient, trilium_manifest: dict, root_note_id: str
) -> dict[str, str]:
    """Tag untagged notes and build triliumNoteId → syncId map."""
    notes_by_id = trilium_manifest["notesByTriliumId"]
    untagged = trilium_manifest.get("untagged", [])
    if untagged:
        tagged_count = 0
        for note in untagged:
            nid = note["triliumNoteId"]
            if nid == root_note_id:
                continue
            tag_note_with_sync_id(client, nid, nid)
            notes_by_id[nid]["syncId"] = nid
            tagged_count += 1
        if tagged_count:
            log(f"[push] tagged {tagged_count} untagged note(s) with gitSyncId")

    return build_id_map(notes_by_id)


def _finalize_meta_clones(
    export_dir: Path, global_meta: dict, global_meta_path: Path,
    notes_by_id: dict, id_map: dict[str, str],
    affected_dirs: set[str] | None = None,
) -> None:
    """Phase 4: inject clone parent IDs, strip stubs, write meta, generate pointer files."""
    sync_id_to_entry: dict[str, dict] = {}
    for nid, te in notes_by_id.items():
        sid = id_map.get(nid)
        if sid:
            sync_id_to_entry[sid] = te
    inject_clone_parent_ids(global_meta.get("files", []), sync_id_to_entry, id_map)
    strip_clone_stubs(global_meta, export_dir=export_dir)

    global_meta_path.write_text(json.dumps(global_meta, indent=2, ensure_ascii=False) + "\n")
    _count, pointer_dirs = generate_clone_pointer_files(export_dir, global_meta)
    if affected_dirs is not None and pointer_dirs:
        affected_dirs.update(pointer_dirs)


def _commit_export(
    worktree: Path, branch: str, export_dir: Path, config,
    affected_dirs: set[str] | None = None,
    commit_message: str | None = None,
) -> None:
    """Phase 5: copy export to temp, format, rewrite home links, commit."""
    with tempfile.TemporaryDirectory(prefix="trilium-git-sync-export-", dir=config.state_dir) as export_tmp:
        export_root = Path(export_tmp) / config.export_subdir
        shutil.copytree(export_dir, export_root)
        pretty_format_export_json_files(export_root)
        home_paths = rewrite_home_links_for_export(export_root, config.home_dir)
        # Generate/update TOC in README
        tmp_readme = Path(export_tmp) / "README.md"
        try:
            from git import Repo as _Repo, GitCommandError as _GitErr
            _repo = _Repo(str(worktree))
            tmp_readme.write_text(_repo.git.show("HEAD:README.md"))
        except (_GitErr, Exception):
            pass
        _generate_toc(export_root, readme_path=tmp_readme)
        if config.use_lfs:
            smudge_lfs_pointers(export_root)
        commit_export(
            worktree, branch, config.export_subdir, export_root,
            config.root_note_id, config.use_lfs,
            affected_section_dirs=affected_dirs,
            commit_message=commit_message,
        )
        if home_paths:
            stage_home_files_post_commit(worktree, home_paths, config)


def _integrate_with_upstream(
    client: TriliumClient,
    worktree: Path,
    branch: str,
    config,
    local_head: str,
    upstream_head: str,
    export_sha: str,
) -> None:
    """Cherry-pick the local export onto upstream HEAD, letting git merge content.

    Flow:
        1. Read upstream meta (before it's overwritten by cherry-pick).
        2. Reset to upstream HEAD.
        3. Cherry-pick the export commit with ``-X theirs`` (local wins on
           line-level conflicts; non-conflicting upstream changes are merged).
        4. Merge metas: keep our export's entries, add upstream-only entries.
        5. Import upstream's contributions into Trilium (notes/content that
           upstream added or changed and that survived the merge).

    Falls back to the timestamp-based pull if cherry-pick fails.
    """
    from git import Repo as _Repo, GitCommandError as _GitErr

    repo = _Repo(str(worktree))
    export_subdir = config.export_subdir

    # 1. Read upstream meta before cherry-pick overwrites it.
    upstream_meta: dict = {}
    try:
        raw = repo.git.show(f"{upstream_head}:{export_subdir}/{META_FILE_NAME}")
        upstream_meta = json.loads(raw)
    except (_GitErr, json.JSONDecodeError, Exception):
        pass

    # 2. Reset to upstream HEAD.
    _git(worktree, "sparse-checkout", "disable", check=False)
    _git(worktree, "reset", "--hard", upstream_head)

    # 3. Cherry-pick our export commit.
    cherry_ok = True
    try:
        repo.git.cherry_pick(export_sha, "-X", "theirs")
        log(f"[sync] cherry-picked {export_sha[:12]} onto {upstream_head[:12]}")
    except _GitErr as exc:
        # -X theirs should resolve most conflicts, but delete/modify
        # or binary conflicts may remain.  Try to auto-resolve.
        try:
            # For any remaining conflicts, prefer our export version.
            repo.git.checkout("--theirs", "--", ".")
            repo.git.add("-A")
            repo.git.execute(["git", "cherry-pick", "--continue", "--no-edit"])
            log(f"[sync] cherry-picked {export_sha[:12]} with conflict resolution")
        except (_GitErr, Exception):
            repo.git.cherry_pick("--abort")
            cherry_ok = False
            log(f"[sync] ⚠ cherry-pick failed, falling back to timestamp-based pull")

    if not cherry_ok:
        # Fallback: apply upstream changes first (with timestamp guard),
        # then re-export.
        _git(worktree, "reset", "--hard", upstream_head)
        _apply_upstream_changes(
            client, worktree, local_head, upstream_head,
            export_subdir, config.use_lfs, config.root_note_id,
            home_dir=config.home_dir,
        )
        _do_export(client, worktree, branch, config)
        return

    # 4. Merge metas: our export entries + upstream-only entries.
    export_dir = worktree / export_subdir
    meta_path = export_dir / META_FILE_NAME
    if meta_path.exists() and upstream_meta:
        export_meta = json.loads(meta_path.read_text())
        merged_meta = _merge_export_metas(export_meta, upstream_meta)
        if merged_meta is not export_meta:
            meta_path.write_text(
                json.dumps(merged_meta, indent=2, ensure_ascii=False) + "\n"
            )
            repo.git.add("--", str(meta_path))
            try:
                repo.git.diff("--cached", "--quiet", "--", str(meta_path))
            except _GitErr:
                # meta changed, amend
                repo.git.commit("--amend", "--no-edit")
                log("[sync] amended commit with merged meta")

    cherry_head = current_head(worktree)

    # 5. Import upstream's contributions into Trilium.
    #    Diff between our export and the cherry-picked result shows exactly
    #    what upstream contributed (including git-merged content).
    changes = compute_diff(worktree, export_sha, cherry_head, export_subdir)
    if not changes:
        log("[pull] no upstream changes after merge")
        return

    log(f"[pull] {len(changes)} file(s) changed by upstream merge")

    export_dir = prepare_export_dir(worktree, export_subdir, config.use_lfs)
    if not export_dir:
        return

    rewrite_home_links_for_import(export_dir, config.home_dir)

    git_manifest = build_git_manifest(export_dir)
    trilium_manifest = build_trilium_manifest(client, config.root_note_id)

    changed_paths: set[str] = set()
    prefix = export_subdir + "/"
    for c in changes:
        for key in ("path", "oldPath", "newPath"):
            p = c.get(key)
            if p:
                if p.startswith(prefix):
                    p = p[len(prefix):]
                changed_paths.add(p)

    _log_changed_paths_as_notes(changed_paths, git_manifest, trilium_manifest)

    plan = build_pull_plan(git_manifest, trilium_manifest, export_dir, changed_paths, root_note_id=config.root_note_id)
    total = sum(plan["summary"].values())
    if total > 0:
        log(f"[pull] applying upstream merge: {plan['summary']}")
        apply_pull_plan(client, plan, export_dir, git_manifest, trilium_manifest, config.root_note_id)
    else:
        log("[pull] no upstream changes to apply after merge")


def _merge_export_metas(export_meta: dict, upstream_meta: dict) -> dict:
    """Merge two meta trees by noteId.

    - Entries in both: export (Trilium) version wins.
    - Entries only in export: kept.
    - Entries only in upstream: added at their upstream parent location.

    Returns ``export_meta`` unchanged if upstream has nothing to add,
    or a new merged dict.
    """
    import copy

    # Collect all noteIds present in the export meta.
    export_ids: set[str] = set()

    def _collect_ids(entries: list) -> None:
        for entry in entries:
            nid = entry.get("noteId", "")
            if nid:
                export_ids.add(nid)
            if entry.get("children"):
                _collect_ids(entry["children"])

    _collect_ids(export_meta.get("files", []))

    # Walk upstream meta and collect entries not present in export.
    upstream_only: list[tuple[str, dict]] = []  # (parent_noteId, entry)

    def _find_upstream_only(entries: list, parent_id: str) -> None:
        for entry in entries:
            nid = entry.get("noteId", "")
            if nid == "root":
                child_parent = nid
                if entry.get("children"):
                    _find_upstream_only(entry["children"], child_parent)
                continue
            if nid and nid not in export_ids:
                # Entire subtree is upstream-only; add it whole.
                upstream_only.append((parent_id, copy.deepcopy(entry)))
            elif nid and entry.get("children"):
                # Entry exists in export but might have upstream-only children.
                _find_upstream_only(entry["children"], nid)

    _find_upstream_only(upstream_meta.get("files", []), "root")

    if not upstream_only:
        return export_meta

    merged = copy.deepcopy(export_meta)
    added = 0
    for parent_id, entry in upstream_only:
        if insert_entry_into_meta(merged, parent_id, entry):
            added += 1
        else:
            # Parent doesn't exist in export — add at root level.
            root_files = merged.get("files", [])
            root_entry = next(
                (e for e in root_files if e.get("noteId") == "root"), None
            )
            if root_entry is not None:
                root_entry.setdefault("children", []).append(entry)
                added += 1

    if added:
        log(f"[sync] merged {added} upstream-only entry/entries into meta")
    return merged

def _apply_incremental_moves(
    client: TriliumClient,
    export_dir: Path,
    global_meta: dict,
    trilium_manifest: dict,
    id_map: dict[str, str],
    root_note_id: str,
    affected_dirs: set[str],
) -> list[dict]:
    """Detect and apply note moves in the export tree.

    Returns the list of applied move descriptors (each with triliumId, syncId,
    title, oldParentSyncId, newParentSyncId) for use in the commit summary.
    """
    moved_notes = detect_export_moves(global_meta, trilium_manifest, id_map, root_note_id)
    applicable_moves = []
    for move in moved_notes:
        new_parent_sid = move["newParentSyncId"]
        # ``"root"`` is a valid new parent even though it isn't a yielded entry.
        new_parent_known = (
            new_parent_sid == "root"
            or find_entry_by_sync_id(global_meta, new_parent_sid) is not None
        )
        if new_parent_known:
            applicable_moves.append(move)
        else:
            old_loc = find_note_path_in_meta(global_meta, move["syncId"])
            old_entry = find_entry_by_sync_id(global_meta, move["syncId"])
            if old_loc:
                _record_entry_affected_dirs(affected_dirs, old_loc[0], old_entry)
            log(
                f"[push] move target parent {move['newParentSyncId']} not yet in export; "
                "removing from old location:"
            )
            log_note_line(
                move.get("triliumNoteId"),
                move["syncId"],
                move.get("title"),
                marker="↔",
                suffix=f"old parent {move['oldParentSyncId']}",
            )
            remove_note_from_export(export_dir, global_meta, move["syncId"], trilium_id=move.get("triliumNoteId"))

    if applicable_moves:
        log(f"[push] {len(applicable_moves)} note(s) moved:")
        for move in applicable_moves:
            new_parent_sid = move["newParentSyncId"]
            old_loc = find_note_path_in_meta(global_meta, move["syncId"])
            old_entry = find_entry_by_sync_id(global_meta, move["syncId"])
            # Record the OLD location's content directory ("Amazon_Wishlist")
            # so its tracked files get re-evaluated and removed at commit time.
            if old_loc:
                _record_entry_affected_dirs(affected_dirs, old_loc[0], old_entry)
            # Record the NEW parent's content directory so the moved files
            # land in the diff.
            if new_parent_sid == "root":
                affected_dirs.add("")
            else:
                new_parent_loc = find_note_path_in_meta(global_meta, new_parent_sid)
                new_parent_entry = find_entry_by_sync_id(global_meta, new_parent_sid)
                if new_parent_entry is not None:
                    npd = new_parent_entry.get("dirFileName", "")
                    base = new_parent_loc[0] if new_parent_loc else ""
                    affected_dirs.add(
                        f"{base}/{npd}" if base and npd else (npd or base)
                    )
            log_note_line(
                move.get("triliumNoteId"),
                move["syncId"],
                move.get("title"),
                marker="↔",
                suffix=f"{move['oldParentSyncId']} → {move['newParentSyncId']}",
            )
            apply_export_move(export_dir, global_meta, move)

    return applicable_moves


def _record_entry_affected_dirs(
    affected_dirs: set[str],
    parent_dir: str,
    entry: dict | None,
) -> None:
    """Add the directory paths that hold an entry's tracked content.

    For an entry with its own ``dirFileName``, the data file and any
    attachments live INSIDE ``parent_dir/dirFileName/``, so that path is
    what commit_export needs to compare against the new tree.
    For a leaf with no own directory, the data file lives directly in
    ``parent_dir/``.
    """
    affected_dirs.add(parent_dir)
    if entry is None:
        return
    dir_name = entry.get("dirFileName", "")
    if dir_name:
        affected_dirs.add(
            f"{parent_dir}/{dir_name}" if parent_dir else dir_name
        )


def _export_subtrees(
    client: TriliumClient,
    roots: list[str],
    export_dir: Path,
    global_meta: dict,
    trilium_manifest: dict,
    notes_by_id: dict,
    id_map: dict[str, str],
    affected_dirs: set[str] | None,
    root_note_id: str = "root",
) -> None:
    """Export each subtree and merge into the export directory.

    When the subtree root is the configured root note, its zip covers the
    entire tree. In that case the extracted result replaces the full
    export directory and meta is adopted wholesale (with sync-ID rewriting
    and clone finalization handled later).
    """
    for root_id in roots:
        root_entry = notes_by_id.get(root_id)
        if not root_entry:
            log(f"[push] ⚠ note={root_id} not in Trilium manifest")
            continue

        sync_id = id_map.get(root_id, root_id)
        title = root_entry.get("title", "?")
        is_root_subtree = root_id == root_note_id
        log("[push] exporting subtree:")
        log_note_line(root_id, sync_id, title)

        export_zip = client.export_markdown_zip(root_id)
        if export_zip is None:
            log("[push] ⚠ export failed:")
            log_note_line(root_id, sync_id, title)
            continue

        with tempfile.TemporaryDirectory(prefix="trilium-subtree-") as tmp:
            subtree_dir = Path(tmp) / "subtree"
            extract_export(export_zip, subtree_dir, pretty=False,
                           root_note_id=root_note_id)

            subtree_meta_path = subtree_dir / META_FILE_NAME
            if not subtree_meta_path.exists():
                continue
            subtree_meta = json.loads(subtree_meta_path.read_text())

            rewrite_ids_in_entries(subtree_meta.get("files", []), id_map)
            rewrite_ids_in_content(subtree_dir, id_map)

            if is_root_subtree:
                # Whole-tree export: replace export directory contents and
                # adopt the extracted meta wholesale.
                _merge_root_subtree(export_dir, subtree_dir, subtree_meta, global_meta)
            else:
                _merge_child_subtree(
                    export_dir, subtree_dir, subtree_meta,
                    global_meta, sync_id, title, root_entry, id_map,
                    affected_dirs,
                )


def _merge_root_subtree(
    export_dir: Path,
    subtree_dir: Path,
    subtree_meta: dict,
    global_meta: dict,
) -> None:
    """Replace the export directory with a full root subtree extract.

    Removes all existing content from ``export_dir`` (except
    ``!!!meta.json`` which is rewritten), then copies everything from the
    extracted subtree.  ``global_meta`` is updated in-place so later
    phases (clone finalization, commit) see the new tree.
    """
    # Remove existing content (preserve the directory itself).
    ensure_dir(export_dir)
    for item in list(export_dir.iterdir()):
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()

    # Copy extracted subtree content.
    for item in subtree_dir.iterdir():
        if item.name == META_FILE_NAME:
            continue
        dest = export_dir / item.name
        if item.is_dir():
            shutil.copytree(item, dest)
        else:
            shutil.copy2(item, dest)

    # Adopt the new meta wholesale.
    global_meta["files"] = subtree_meta.get("files", [])
    global_meta["formatVersion"] = subtree_meta.get("formatVersion", 2)


def _merge_child_subtree(
    export_dir: Path,
    subtree_dir: Path,
    subtree_meta: dict,
    global_meta: dict,
    sync_id: str,
    title: str,
    root_entry: dict,
    id_map: dict[str, str],
    affected_dirs: set[str] | None,
) -> None:
    """Merge a non-root subtree into the export directory."""
    target_parent_dir, is_new_note, parent_sync_id = _resolve_subtree_target(
        global_meta, sync_id, title, root_entry, id_map,
    )
    if target_parent_dir is None:
        return

    if affected_dirs is not None:
        affected_dirs.add(target_parent_dir)

    target_dir = export_dir / target_parent_dir if target_parent_dir else export_dir

    subtree_root_entry = subtree_meta["files"][0] if subtree_meta.get("files") else None
    if not subtree_root_entry:
        return

    # Remove old files for existing notes
    if not is_new_note:
        # Record the old entry's directory in affected_dirs BEFORE
        # removing it, so commit_export will process that section and
        # properly stage the deletion (important when a note is renamed
        # and its dirFileName changes).
        if affected_dirs is not None:
            old_entry = find_entry_by_sync_id(global_meta, sync_id)
            if old_entry:
                old_dir = old_entry.get("dirFileName", "")
                if old_dir:
                    old_rel = f"{target_parent_dir}/{old_dir}" if target_parent_dir else old_dir
                    affected_dirs.add(old_rel)
        _remove_old_subtree_files(global_meta, sync_id, target_dir)

    # Copy new files
    ensure_dir(target_dir)
    for item in subtree_dir.iterdir():
        if item.name == META_FILE_NAME:
            continue
        dest = target_dir / item.name
        if dest.exists():
            if dest.is_dir():
                shutil.rmtree(dest)
            else:
                dest.unlink()
        if item.is_dir():
            shutil.copytree(item, dest)
            # Register ALL subdirectories (recursively) so commit_export
            # processes every section with files, not just the top-level.
            if affected_dirs is not None:
                for dirpath, _, _ in os.walk(dest):
                    rel = Path(dirpath).relative_to(export_dir).as_posix()
                    affected_dirs.add(rel)
        else:
            shutil.copy2(item, dest)

    # Update global meta
    if is_new_note:
        insert_entry_into_meta(global_meta, parent_sync_id, subtree_root_entry)
    else:
        splice_meta_entry(global_meta, sync_id, target_parent_dir, subtree_root_entry)


def _resolve_subtree_target(
    global_meta: dict, sync_id: str, title: str, root_entry: dict, id_map: dict[str, str],
) -> tuple[str | None, bool, str | None]:
    """Determine where a subtree should be placed in the export.

    Returns (target_parent_dir, is_new_note, parent_sync_id).
    Returns (None, ..., ...) if the note should be skipped.
    """
    subtree_path = find_note_path_in_meta(global_meta, sync_id)
    if subtree_path is not None:
        return (subtree_path[0], False, None)

    parent_trilium_id = root_entry.get("parentTriliumNoteId")
    parent_sync_id = id_map.get(parent_trilium_id, parent_trilium_id) if parent_trilium_id else None
    if not parent_sync_id:
        log(f"[push] ⚠ not in meta and no parent → skip:")
        log_note_line(root_entry.get("triliumNoteId"), sync_id, title)
        return (None, True, None)

    # New top-level note: parent is the synthetic ``"root"`` which is never
    # yielded by walk_entries. Its content lives directly under export_dir.
    if parent_sync_id == "root":
        log(f"[push] new note → parent syncId=root:")
        log_note_line(root_entry.get("triliumNoteId"), sync_id, title)
        return ("", True, parent_sync_id)

    parent_entry = find_entry_by_sync_id(global_meta, parent_sync_id)
    if not parent_entry:
        log(f"[push] ⚠ parent {parent_sync_id} not in meta → skip:")
        log_note_line(root_entry.get("triliumNoteId"), sync_id, title)
        return (None, True, None)
    parent_path_info = find_note_path_in_meta(global_meta, parent_sync_id)
    if parent_path_info:
        ppd, _ = parent_path_info
        parent_dir_name = parent_entry.get("dirFileName", "")
        target_parent_dir = f"{ppd}/{parent_dir_name}" if ppd and parent_dir_name else (parent_dir_name or ppd)
    else:
        target_parent_dir = parent_entry.get("dirFileName", "")
    log(f"[push] new note → parent syncId={parent_sync_id}:")
    log_note_line(root_entry.get("triliumNoteId"), sync_id, title)
    return (target_parent_dir, True, parent_sync_id)


def _remove_old_subtree_files(global_meta: dict, sync_id: str, target_dir: Path) -> None:
    """Remove old files for an existing note before replacing with new export."""
    old_entry = find_entry_by_sync_id(global_meta, sync_id)
    if not old_entry:
        return
    old_dir_name = old_entry.get("dirFileName", "")
    if old_dir_name:
        # After ``_restructure_notes_as_dirs``, the data file and
        # attachments live INSIDE the note's own directory.  Removing the
        # directory is sufficient; touching ``target_dir/<dataFileName>``
        # separately would clobber an *unrelated* file at the parent
        # level (most commonly the parent note's own ``README.md``).
        old_path = target_dir / old_dir_name
        if old_path.is_dir():
            shutil.rmtree(old_path)
    else:
        # Flat layout (no own directory): data file and attachments sit
        # directly in ``target_dir``.
        old_data_file = old_entry.get("dataFileName", "")
        if old_data_file:
            old_file = target_dir / old_data_file
            if old_file.exists():
                old_file.unlink()
        for att in old_entry.get("attachments", []):
            adf = att.get("dataFileName", "")
            if adf:
                att_path = target_dir / adf
                if att_path.exists():
                    att_path.unlink()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _git(worktree: Path, *args: str, check: bool = True) -> str:
    """Convenience alias for run_git."""
    return run_git(worktree, *args, check=check)


def _build_incremental_commit_message(
    config,
    *,
    created: list[dict],
    updated: list[dict],
    deleted: list[dict],
    moved: list[dict],
    affected_dirs: set[str] | None = None,
) -> str:
    """Build a multi-line commit message summarizing this export.

    Layout:
        sync: export Trilium <root> from <host> (<count summary>)

        <N> created, <M> updated, <K> deleted, <L> moved

        Created:
          - [trilium:.. sync:..] title
        Updated:
          - ...
        Deleted:
          - ...
        Moved:
          - [trilium:.. sync:..] title (old → new)

        Root: <root_note_id>
        Host: <hostname>
        Affected sections: <N>
    """
    hostname = socket.gethostname()
    counts: list[str] = []
    if created:
        counts.append(f"+{len(created)}")
    if updated:
        counts.append(f"~{len(updated)}")
    if deleted:
        counts.append(f"-{len(deleted)}")
    if moved:
        counts.append(f"↔{len(moved)}")
    summary = " ".join(counts) if counts else "no-op"

    subject = f"sync: export Trilium {config.root_note_id} from {hostname} ({summary})"
    lines: list[str] = [subject, ""]

    detail_counts: list[str] = []
    if created:
        detail_counts.append(f"{len(created)} created")
    if updated:
        detail_counts.append(f"{len(updated)} updated")
    if deleted:
        detail_counts.append(f"{len(deleted)} deleted")
    if moved:
        detail_counts.append(f"{len(moved)} moved")
    if detail_counts:
        lines.append(", ".join(detail_counts))
        lines.append("")

    def _section(heading: str, notes: list[dict], with_move: bool = False) -> None:
        if not notes:
            return
        lines.append(f"{heading}:")
        for n in notes:
            suffix = ""
            if with_move:
                suffix = f"({n.get('oldParentSyncId', '?')} → {n.get('newParentSyncId', '?')})"
            lines.append(format_note_line(
                n.get("triliumId") or n.get("triliumNoteId"),
                n.get("syncId"),
                n.get("title"),
                suffix=suffix,
            ))
        lines.append("")

    _section("Created", created)
    _section("Updated", updated)
    _section("Deleted", deleted)
    _section("Moved", moved, with_move=True)

    # Trailing metadata block
    lines.append(f"Root: {config.root_note_id}")
    lines.append(f"Host: {hostname}")
    if affected_dirs is not None:
        non_empty = sorted(d for d in affected_dirs if d)
        lines.append(f"Affected sections: {len(non_empty)}")
    return "\n".join(lines).rstrip() + "\n"


def _log_changed_paths_as_notes(
    changed_paths: set[str],
    git_manifest: dict,
    trilium_manifest: dict,
) -> None:
    """Map changed file paths to their owning notes and log one descriptor per note."""
    if not changed_paths:
        return

    git_notes = git_manifest["notesBySyncId"]
    trilium_notes_by_sync = trilium_manifest["notesBySyncId"]

    seen_sync_ids: set[str] = set()
    note_lines: list[tuple[str | None, str | None, str | None, str]] = []
    meta_only = False
    unmapped_paths: list[str] = []

    for path in sorted(changed_paths):
        if path == META_FILE_NAME or path.endswith("/" + META_FILE_NAME):
            meta_only = True
            continue

        owner_sync_id: str | None = None
        owner_note: dict | None = None
        for sid, note in git_notes.items():
            content_path = note.get("contentPath")
            dir_path = note.get("dirPath")
            if content_path == path or (dir_path and (path == dir_path or path.startswith(dir_path + "/"))):
                owner_sync_id = sid
                owner_note = note
                break

        if owner_sync_id is None:
            unmapped_paths.append(path)
            continue
        if owner_sync_id in seen_sync_ids:
            continue
        seen_sync_ids.add(owner_sync_id)

        trilium_entry = trilium_notes_by_sync.get(owner_sync_id, {})
        note_lines.append((
            trilium_entry.get("triliumNoteId"),
            owner_sync_id,
            (trilium_entry.get("title") if trilium_entry else None) or (owner_note.get("title") if owner_note else None),
            "",
        ))

    if note_lines:
        log(f"[pull] {len(note_lines)} note(s) affected by diff:")
        log_note_lines(note_lines)
    if meta_only and not note_lines:
        log("[pull] manifest-only changes")
    if unmapped_paths:
        log(f"[pull] {len(unmapped_paths)} changed path(s) not mapped to any note:")
        for p in unmapped_paths:
            log(f"    {p}")
