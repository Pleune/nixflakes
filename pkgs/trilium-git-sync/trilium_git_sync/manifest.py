"""Manifest building and comparison.

Builds flat maps of note metadata from both git export trees and live Trilium,
then computes pull plans describing what needs to change.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .client import TriliumClient
from .common import META_FILE_NAME, log


SYNC_ID_ATTR = "gitSyncId"


def build_id_map(notes_by_trilium_id: dict[str, Any]) -> dict[str, str]:
    """Build triliumNoteId → syncId map from a manifest's notesByTriliumId."""
    return {nid: entry.get("syncId") or nid for nid, entry in notes_by_trilium_id.items()}


# ---------------------------------------------------------------------------
# Git manifest
# ---------------------------------------------------------------------------

def build_git_manifest(export_dir: Path) -> dict[str, Any]:
    """Parse !!!meta.json and build a flat map of gitSyncId → note metadata."""
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return {"notesBySyncId": {}, "meta": {}}
    meta = json.loads(meta_path.read_text())
    notes: dict[str, dict[str, Any]] = {}
    _walk_meta(meta.get("files", []), parent_sync_id=None, parent_dir="", notes=notes)
    return {"notesBySyncId": notes, "meta": meta}


def _walk_meta(entries: list, parent_sync_id: str | None, parent_dir: str, notes: dict) -> None:
    for entry in entries:
        note_id = entry.get("noteId")
        if not note_id or note_id == "root":
            # Recurse into root wrapper if present.
            # Pass ``"root"`` as parent_sync_id so top-level notes get
            # ``parentSyncId: "root"`` (consistent with walk_entries in
            # meta_tree.py), not None which is indistinguishable from
            # "not found in meta".
            dir_name = entry.get("dirFileName", "")
            child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
            if entry.get("children"):
                _walk_meta(entry["children"], "root", child_dir, notes)
            continue

        # Skip clone stubs (noteId already seen with real content)
        if note_id in notes:
            # Already have canonical entry — record additional parent as clone
            existing = notes[note_id]
            existing_parent_sids = {c["syncId"] if isinstance(c, dict) else c for c in existing.get("cloneParentSyncIds", [])}
            if parent_sync_id and parent_sync_id not in existing_parent_sids:
                existing.setdefault("cloneParentSyncIds", []).append({
                    "syncId": parent_sync_id,
                    "prefix": entry.get("prefix"),
                    "notePosition": entry.get("notePosition"),
                })
            continue

        # Skip entries explicitly marked as clones (no content)
        if not entry.get("dataFileName") and not entry.get("dirFileName") and not entry.get("children"):
            # Bare stub with just noteId+title — likely a leftover clone reference
            continue

        dir_name = entry.get("dirFileName", "")
        entry_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
        data_file = entry.get("dataFileName", "")
        # Content lives inside the note's own dir when it has a dirFileName
        note_type = entry.get("type", "text")
        if dir_name and data_file:
            content_path = f"{entry_dir}/{data_file}" if entry_dir else data_file
        elif parent_dir and data_file:
            content_path = f"{parent_dir}/{data_file}"
        else:
            content_path = data_file

        notes[note_id] = {
            "syncId": note_id,
            "parentSyncId": parent_sync_id,
            "title": entry.get("title"),
            "type": entry.get("type"),
            "mime": entry.get("mime"),
            "format": entry.get("format"),
            "notePosition": entry.get("notePosition"),
            "isExpanded": entry.get("isExpanded", False),
            "prefix": entry.get("prefix"),
            "contentPath": content_path or None,
            "dirPath": entry_dir or None,
            "attributes": entry.get("attributes", []),
            "attachments": entry.get("attachments", []),
            "childSyncIds": [c.get("noteId") for c in entry.get("children", []) if c.get("noteId")],
            "cloneParentSyncIds": entry.get("cloneParentSyncIds", []),
        }

        if entry.get("children"):
            _walk_meta(entry["children"], note_id, entry_dir, notes)


# ---------------------------------------------------------------------------
# Trilium manifest
# ---------------------------------------------------------------------------

def build_trilium_manifest(client: TriliumClient, root_note_id: str) -> dict[str, Any]:
    """Walk Trilium tree and build maps: gitSyncId → trilium note info, and noteId → gitSyncId."""
    notes_by_sync_id: dict[str, dict[str, Any]] = {}
    notes_by_trilium_id: dict[str, dict[str, Any]] = {}
    untagged: list[dict[str, Any]] = []

    def walk(note_id: str, parent_note_id: str | None) -> None:
        if note_id in notes_by_trilium_id:
            # Already visited — this is a clone (additional parent placement)
            if parent_note_id:
                entry = notes_by_trilium_id[note_id]
                entry.setdefault("allParentNoteIds", []).append(parent_note_id)
                # Fetch branch to capture prefix and position for clone placement
                branch_id = f"{parent_note_id}_{note_id}"
                try:
                    branch = client.get_branch(branch_id)
                    prefix = branch.get("prefix") if branch else None
                    note_position = branch.get("notePosition") if branch else None
                except Exception:
                    prefix = None
                    note_position = None
                entry.setdefault("cloneBranches", []).append({
                    "parentNoteId": parent_note_id,
                    "prefix": prefix,
                    "notePosition": note_position,
                })
            return
        note = client.get_note(note_id)
        if note is None:
            return  # note doesn't exist (deleted, hidden, or stale reference)

        sync_id = None
        for attr in note.get("attributes", []):
            if attr.get("type") == "label" and attr.get("name") == SYNC_ID_ATTR:
                sync_id = attr.get("value")
                break

        entry = {
            "triliumNoteId": note_id,
            "syncId": sync_id,
            "parentTriliumNoteId": parent_note_id,
            "allParentNoteIds": [parent_note_id] if parent_note_id else [],
            "title": note.get("title"),
            "type": note.get("type"),
            "mime": note.get("mime"),
            "blobId": note.get("blobId"),
            "childNoteIds": [c for c in note.get("childNoteIds", []) if not c.startswith("_")],
            "attributes": [a for a in note.get("attributes", []) if a.get("name") != SYNC_ID_ATTR],
            "dateModified": note.get("utcDateModified"),
        }

        notes_by_trilium_id[note_id] = entry
        if sync_id:
            notes_by_sync_id[sync_id] = entry
        else:
            untagged.append(entry)

        for child_id in entry["childNoteIds"]:
            walk(child_id, note_id)

    walk(root_note_id, None)
    return {
        "notesBySyncId": notes_by_sync_id,
        "notesByTriliumId": notes_by_trilium_id,
        "untagged": untagged,
    }


# ---------------------------------------------------------------------------
# Pull plan
# ---------------------------------------------------------------------------

def build_pull_plan(
    git_manifest: dict[str, Any],
    trilium_manifest: dict[str, Any],
    export_dir: Path,
    changed_paths: set[str] | None = None,
    commit_time: datetime | None = None,
    root_note_id: str = "root",
) -> dict[str, Any]:
    """Compare git manifest against Trilium manifest and produce a pull plan.

    If changed_paths is provided, only consider notes whose content/dir paths
    intersect with the changed set. This scopes updates to only what actually
    changed in the git diff.

    If commit_time is provided and changed_paths is None (full pull plan),
    it's used as a staleness heuristic: notes not modified in Trilium since
    commit_time are assumed to match the git content and skipped.

    Returns a plan with:
    - creates: notes in git not in Trilium (need import)
    - updates: notes in both but content/metadata differs
    - deletes: notes in Trilium (with gitSyncId) but absent from git
    - moves: notes whose parent changed
    """
    git_notes = git_manifest["notesBySyncId"]
    trilium_notes = trilium_manifest["notesBySyncId"]

    creates: list[dict[str, Any]] = []
    updates: list[dict[str, Any]] = []
    deletes: list[dict[str, Any]] = []
    moves: list[dict[str, Any]] = []

    for sync_id, git_note in git_notes.items():
        trilium_note = trilium_notes.get(sync_id)
        if trilium_note is None:
            if changed_paths is None or _note_paths_in_set(git_note, changed_paths):
                creates.append({
                    "syncId": sync_id,
                    "gitNote": git_note,
                    "reason": "not found in Trilium",
                })
            continue

        # Skip notes not affected by the diff (when filtering)
        if changed_paths is not None and not _note_paths_in_set(git_note, changed_paths):
            continue

        # Check for move (parent changed)
        git_parent = git_note.get("parentSyncId")
        trilium_parent_id = trilium_note.get("parentTriliumNoteId")
        trilium_parent_entry = trilium_manifest["notesByTriliumId"].get(trilium_parent_id or "")
        # The configured root has no gitSyncId label; map its Trilium id to
        # the synthetic ``"root"`` sentinel used by the git manifest's
        # ``parentSyncId: "root"`` for top-level notes.
        if trilium_parent_id == root_note_id:
            trilium_parent_sync_id = "root"
        else:
            trilium_parent_sync_id = trilium_parent_entry.get("syncId") if trilium_parent_entry else None
        if git_parent and trilium_parent_sync_id and git_parent != trilium_parent_sync_id:
            moves.append({
                "syncId": sync_id,
                "gitNote": git_note,
                "triliumNote": trilium_note,
                "oldParentSyncId": trilium_parent_sync_id,
                "newParentSyncId": git_parent,
                "reason": "parent changed in git",
            })

        # Check for content/metadata changes
        changes = _detect_changes(git_note, trilium_note, export_dir, changed_paths, commit_time)
        if changes:
            updates.append({
                "syncId": sync_id,
                "gitNote": git_note,
                "triliumNote": trilium_note,
                "changes": changes,
            })

    # Check for deletes
    meta_in_diff = changed_paths is None or any("!!!meta.json" in p for p in changed_paths)
    if meta_in_diff:
        for sync_id, trilium_note in trilium_notes.items():
            if sync_id not in git_notes:
                # Skip the root note itself (always exists, never in git manifest).
                if trilium_note.get("triliumNoteId") == root_note_id:
                    continue
                deletes.append({
                    "syncId": sync_id,
                    "triliumNote": trilium_note,
                    "reason": "deleted upstream",
                })

    plan = {
        "creates": creates,
        "updates": updates,
        "deletes": deletes,
        "moves": moves,
        "summary": {
            "createCount": len(creates),
            "updateCount": len(updates),
            "deleteCount": len(deletes),
            "moveCount": len(moves),
        },
    }
    log(
        f"[pull] plan: +{len(creates)} ~{len(updates)} -{len(deletes)} ↔{len(moves)}"
    )
    return plan


# ---------------------------------------------------------------------------
# Change detection helpers
# ---------------------------------------------------------------------------

def detect_local_deletions(
    client: TriliumClient, previously_exported: set[str], root_note_id: str
) -> list[str]:
    """Find syncIds that were in our last export but are no longer in Trilium.
    These are notes the user deleted locally."""
    if not previously_exported:
        return []

    trilium_manifest = build_trilium_manifest(client, root_note_id)
    current_sync_ids = set(trilium_manifest["notesBySyncId"].keys())
    deleted = sorted(previously_exported - current_sync_ids)
    return deleted


def find_changed_notes_since(
    client: TriliumClient, worktree: Path, head: str | None,
    root_note_id: str, previously_exported: set[str] | None = None,
) -> list[str] | None:
    """Find Trilium noteIds modified after the last git commit OR present in Trilium but missing from git.
    Returns None if we can't determine (need full export), empty list if nothing changed,
    or list of changed noteIds."""
    from git import Repo, GitCommandError

    if not head:
        return None  # no commit yet, need full export

    # Get the commit timestamp
    repo = Repo(str(worktree))
    try:
        timestamp = repo.git.log("-1", "--format=%aI", head)
    except GitCommandError:
        return None
    if not timestamp.strip():
        return None

    try:
        commit_dt = datetime.fromisoformat(timestamp.strip())
    except (ValueError, TypeError):
        return None

    # A change to the root note itself can only be reproduced by a full
    # export: the root note's content lives at export/README.md and is
    # only (re)written when the whole-tree (root) subtree is exported.
    # There is no way to incrementally export "just the root note". So if
    # the root note was modified after the last commit, collapse the
    # changed set to exactly [root_note_id]. find_topmost_roots() keeps
    # that as [root], which sync.py treats as a full export.
    root_note = client.get_note(root_note_id)
    if root_note is not None:
        root_modified = root_note.get("utcDateModified", "")
        if root_modified:
            root_dt = _parse_trilium_datetime(root_modified)
            if root_dt is not None and root_dt > commit_dt:
                return [root_note_id]

    # Walk Trilium tree, collect notes modified after commit
    changed: list[str] = []

    def walk(note_id: str, visited: set) -> None:
        if note_id in visited:
            return
        visited.add(note_id)
        n = client.get_note(note_id)
        if n is None:
            return
        modified = n.get("utcDateModified", "")
        if modified and note_id != root_note_id:
            note_dt = _parse_trilium_datetime(modified)
            if note_dt is not None and note_dt > commit_dt:
                changed.append(note_id)
        for child_id in n.get("childNoteIds", []):
            if not child_id.startswith("_"):
                walk(child_id, visited)

    walk(root_note_id, set())

    # Also detect notes in Trilium that are not in the git export at all
    if previously_exported is not None:
        trilium_manifest = build_trilium_manifest(client, root_note_id)
        all_trilium_sync_ids = set(trilium_manifest["notesBySyncId"].keys())
        missing_tagged = all_trilium_sync_ids - previously_exported - {root_note_id}
        untagged_ids = {n["triliumNoteId"] for n in trilium_manifest.get("untagged", [])}
        missing_untagged = untagged_ids - {root_note_id}

        for sid in missing_tagged:
            entry = trilium_manifest["notesBySyncId"].get(sid)
            if entry:
                nid = entry["triliumNoteId"]
                if nid not in changed:
                    changed.append(nid)
        for nid in missing_untagged:
            if nid not in changed:
                changed.append(nid)

    return changed


def find_topmost_roots(client: TriliumClient, changed_ids: list[str]) -> list[str]:
    """Find the topmost ancestors in the changed set (avoid exporting nested subtrees)."""
    changed_set = set(changed_ids)
    roots: list[str] = []
    for note_id in changed_ids:
        n = client.get_note(note_id)
        if n is None:
            continue
        parent_ids = n.get("parentNoteIds", [])
        shadowed = False
        for pid in parent_ids:
            if pid in changed_set:
                shadowed = True
                break
        if not shadowed:
            roots.append(note_id)
    return roots


def detect_export_moves(
    global_meta: dict, trilium_manifest: dict, id_map: dict[str, str], root_note_id: str
) -> list[dict]:
    """Detect notes that moved to a different parent since last export.
    Returns list of {syncId, triliumNoteId, oldParentSyncId, newParentSyncId, title}."""
    from .meta_tree import find_entry_by_sync_id, find_parent_sync_id_in_meta

    moves: list[dict] = []
    notes_by_id = trilium_manifest["notesByTriliumId"]

    for trilium_id, entry in notes_by_id.items():
        if trilium_id == root_note_id:
            continue
        sync_id = entry.get("syncId")
        if not sync_id:
            continue

        parent_trilium_id = entry.get("parentTriliumNoteId")
        if not parent_trilium_id:
            continue
        current_parent_sync_id = id_map.get(parent_trilium_id)

        meta_parent_sync_id = find_parent_sync_id_in_meta(global_meta, sync_id)
        if meta_parent_sync_id is None:
            continue

        if current_parent_sync_id and meta_parent_sync_id and current_parent_sync_id != meta_parent_sync_id:
            all_parent_ids = entry.get("allParentNoteIds", [])
            all_parent_sync_ids = {id_map.get(pid, pid) for pid in all_parent_ids}
            if meta_parent_sync_id in all_parent_sync_ids:
                continue

            moves.append({
                "syncId": sync_id,
                "triliumNoteId": trilium_id,
                "oldParentSyncId": meta_parent_sync_id,
                "newParentSyncId": current_parent_sync_id,
                "title": entry.get("title", "?"),
            })

    return moves


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _note_paths_in_set(git_note: dict, changed_paths: set[str]) -> bool:
    """Check if any of the note's file paths appear in the changed_paths set."""
    content_path = git_note.get("contentPath")
    if content_path and content_path in changed_paths:
        return True
    dir_path = git_note.get("dirPath")
    if dir_path and git_note.get("childSyncIds"):
        for p in changed_paths:
            if p.startswith(dir_path + "/") or p == dir_path:
                return True
    return False


def _detect_changes(
    git_note: dict,
    trilium_note: dict,
    export_dir: Path,
    changed_paths: set[str] | None = None,
    commit_time: datetime | None = None,
) -> list[str]:
    """Detect differences between a git note and its Trilium counterpart.

    When ``commit_time`` is provided and ``changed_paths`` is None (full pull
    plan with no diff info), notes whose Trilium ``utcDateModified`` is older
    than the commit are skipped — the git content is assumed to match what was
    previously exported.  This avoids needless updates during a full pull.

    In the normal incremental path (``changed_paths`` provided), only notes
    whose files appear in the diff are considered.
    """
    changes: list[str] = []

    if git_note.get("title") != trilium_note.get("title"):
        changes.append("title")

    if git_note.get("type") != trilium_note.get("type"):
        changes.append("type")

    content_path = git_note.get("contentPath")
    if content_path:
        if changed_paths is not None:
            # Incremental: only flag content when the file is in the diff.
            if content_path in changed_paths:
                full_path = export_dir / content_path
                if full_path.exists() and full_path.is_file():
                    changes.append("content")
        else:
            # Full pull plan.  Use commit timestamp to skip notes that
            # haven't been modified since the last export.
            full_path = export_dir / content_path
            if full_path.exists() and full_path.is_file():
                if commit_time is not None:
                    trilium_modified = _parse_trilium_datetime(
                        trilium_note.get("dateModified", "")
                    )
                    if trilium_modified is None or trilium_modified > commit_time:
                        changes.append("content")
                else:
                    changes.append("content")

    git_attrs = git_note.get("attributes", [])
    trilium_attrs = trilium_note.get("attributes", [])
    if _normalize_attrs(git_attrs) != _normalize_attrs(trilium_attrs):
        changes.append("attributes")

    return changes


def _parse_trilium_datetime(value: str) -> datetime | None:
    """Parse Trilium's ``utcDateModified`` string into a timezone-aware datetime."""
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%fZ").replace(
            tzinfo=timezone.utc
        )
    except (ValueError, TypeError):
        return None


def _normalize_attrs(attrs: list) -> list[tuple]:
    """Normalize attributes for comparison (works for both git and Trilium formats)."""
    return sorted(
        (a.get("type", "label"), a.get("name", ""), a.get("value", ""))
        for a in attrs
        if a.get("name") != SYNC_ID_ATTR
    )
