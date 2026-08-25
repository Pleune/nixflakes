"""Apply changes to Trilium: create, update, delete, move notes.

Uses the import API for bulk creation (markdown→HTML conversion) and ETAPI
for individual updates, deletes, moves, and attribute sync.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .client import TriliumClient
from .common import format_note_line, log, log_note_line, log_note_lines
from .manifest import SYNC_ID_ATTR, build_git_manifest, build_trilium_manifest
from .meta_tree import find_entry_by_sync_id as _find_entry_in_meta


def _git_create_descriptor(create: dict) -> tuple[str | None, str | None, str | None]:
    """(triliumId, syncId, title) for a planned create entry."""
    git_note = create.get("gitNote", {})
    return (None, create.get("syncId"), git_note.get("title"))


def _trilium_descriptor(trilium_note: dict, sync_id: str | None) -> tuple[str | None, str | None, str | None]:
    """(triliumId, syncId, title) for an existing Trilium note dict."""
    return (
        trilium_note.get("triliumNoteId"),
        sync_id if sync_id is not None else trilium_note.get("syncId"),
        trilium_note.get("title"),
    )


# ---------------------------------------------------------------------------
# Tag notes with gitSyncId
# ---------------------------------------------------------------------------

def tag_note_with_sync_id(client: TriliumClient, trilium_note_id: str, sync_id: str) -> bool:
    """Set #gitSyncId=<sync_id> on a Trilium note. Returns False if note doesn't exist."""
    from .client import HttpError
    try:
        client.create_attribute({"noteId": trilium_note_id, "type": "label", "name": SYNC_ID_ATTR, "value": sync_id})
        return True
    except HttpError as e:
        if e.status == 404:
            return False
        raise
    except Exception:
        return False


def tag_all_untagged(client: TriliumClient, trilium_manifest: dict[str, Any], git_manifest: dict[str, Any],
                     root_note_id: str = "root") -> int:
    """After an import, find notes without #gitSyncId and match them to git noteIds
    by walking the tree structure (title + parent hierarchy).

    Returns count of notes tagged.
    """
    untagged = trilium_manifest.get("untagged", [])
    if not untagged:
        return 0

    git_notes = git_manifest["notesBySyncId"]
    already_tagged = set(trilium_manifest.get("notesBySyncId", {}).keys())

    # Build a lookup: (parentSyncId, title) → list of git syncIds
    parent_title_map: dict[tuple, list[str]] = {}
    for sync_id, note in git_notes.items():
        key = (note.get("parentSyncId"), note.get("title", ""))
        parent_title_map.setdefault(key, []).append(sync_id)

    # Simple title→syncId for fallback
    title_map: dict[str, list[str]] = {}
    for sync_id, note in git_notes.items():
        title_map.setdefault(note.get("title", ""), []).append(sync_id)

    # triliumNoteId → syncId map (for already-tagged parents)
    trilium_id_to_sync: dict[str, str] = {}
    for sync_id, entry in trilium_manifest.get("notesBySyncId", {}).items():
        trilium_id_to_sync[entry["triliumNoteId"]] = sync_id

    # Process top-down (by tree depth) so parents get tagged first
    notes_by_trilium_id = trilium_manifest.get("notesByTriliumId", {})

    def depth_of(note: dict) -> int:
        d = 0
        pid = note.get("parentTriliumNoteId")
        while pid and pid in notes_by_trilium_id and d < 50:
            d += 1
            pid = notes_by_trilium_id[pid].get("parentTriliumNoteId")
        return d

    untagged_sorted = sorted(untagged, key=depth_of)

    tagged = 0
    for trilium_note in untagged_sorted:
        title = trilium_note.get("title", "")
        parent_trilium_id = trilium_note.get("parentTriliumNoteId", "")
        # The configured root's triliumNoteId has no gitSyncId label; the
        # git manifest uses ``parentSyncId: "root"`` for top-level notes, so
        # map it explicitly onto the synthetic ``"root"`` sentinel.
        parent_sync_id = (
            "root" if parent_trilium_id == root_note_id
            else trilium_id_to_sync.get(parent_trilium_id)
        )

        # Try hierarchy match first: (parentSyncId, title)
        candidates = []
        if parent_sync_id is not None:
            candidates = parent_title_map.get((parent_sync_id, title), [])

        candidates = [c for c in candidates if c not in already_tagged]

        if len(candidates) == 1:
            sync_id = candidates[0]
            if tag_note_with_sync_id(client, trilium_note["triliumNoteId"], sync_id):
                already_tagged.add(sync_id)
                trilium_id_to_sync[trilium_note["triliumNoteId"]] = sync_id
                tagged += 1
            continue

        # Multiple candidates: use notePosition to disambiguate
        if len(candidates) > 1:
            trilium_children = trilium_manifest.get("notesByTriliumId", {}).get(parent_trilium_id, {}).get("childNoteIds", [])
            trilium_pos = trilium_children.index(trilium_note["triliumNoteId"]) if trilium_note["triliumNoteId"] in trilium_children else -1
            sorted_candidates = sorted(candidates, key=lambda s: git_notes.get(s, {}).get("notePosition", 0))
            if 0 <= trilium_pos < len(sorted_candidates):
                sync_id = sorted_candidates[trilium_pos]
                if tag_note_with_sync_id(client, trilium_note["triliumNoteId"], sync_id):
                    already_tagged.add(sync_id)
                    trilium_id_to_sync[trilium_note["triliumNoteId"]] = sync_id
                    tagged += 1
                continue

        # Fallback: unique title match
        if not candidates:
            candidates = [c for c in title_map.get(title, []) if c not in already_tagged]

        if len(candidates) == 1:
            sync_id = candidates[0]
            if tag_note_with_sync_id(client, trilium_note["triliumNoteId"], sync_id):
                already_tagged.add(sync_id)
                trilium_id_to_sync[trilium_note["triliumNoteId"]] = sync_id
                tagged += 1

    if tagged:
        log(f"[tag] ✓ {tagged} notes matched")
    return tagged


# ---------------------------------------------------------------------------
# Create notes via import API
# ---------------------------------------------------------------------------

def apply_creates(
    client: TriliumClient,
    creates: list[dict[str, Any]],
    export_dir: Path,
    git_manifest: dict[str, Any],
    trilium_manifest: dict[str, Any],
    root_note_id: str = "root",
) -> list[dict[str, Any]]:
    """Import new notes into Trilium via import API.

    Groups creates by parent, builds targeted ZIPs, imports top-down.
    Returns list of {syncId} for post-tagging.
    """
    if not creates:
        return []

    create_sync_ids = {c["syncId"] for c in creates}
    git_notes = git_manifest["notesBySyncId"]

    # Find topmost creates (whose parents are NOT also being created)
    topmost: list[dict] = []
    nested: set[str] = set()
    for c in creates:
        parent_sid = c["gitNote"].get("parentSyncId")
        if parent_sid in create_sync_ids:
            nested.add(c["syncId"])
        else:
            topmost.append(c)

    # Group topmost creates by parent syncId
    by_parent: dict[str | None, list[dict]] = {}
    for c in topmost:
        parent_sid = c["gitNote"].get("parentSyncId")
        by_parent.setdefault(parent_sid, []).append(c)

    all_created: list[dict] = []

    for parent_sid, group in by_parent.items():
        # Find parent's Trilium noteId
        parent_entry = None
        if parent_sid is None or parent_sid == "root":
            parent_trilium_id = root_note_id
        else:
            parent_entry = trilium_manifest["notesBySyncId"].get(parent_sid)
            if parent_entry:
                parent_trilium_id = parent_entry["triliumNoteId"]
            else:
                trilium_manifest = build_trilium_manifest(client, root_note_id)
                parent_entry = trilium_manifest["notesBySyncId"].get(parent_sid)
                if parent_entry:
                    parent_trilium_id = parent_entry["triliumNoteId"]
                else:
                    log(f"[pull] ⚠ parent syncId={parent_sid} not found, skipping {len(group)} note(s):")
                    log_note_lines(_git_create_descriptor(c) for c in group)
                    continue

        # Import notes one at a time to avoid Trilium batch import issues
        # ("Missing parent note ID" when multiple subtrees are in one ZIP)
        parent_title = parent_entry.get("title", "?") if parent_entry else "root"
        for c in group:
            note_title = c["gitNote"].get("title", "?")
            sync_id = c.get("syncId")
            try:
                zip_bytes = _build_sparse_import_zip([c], export_dir, git_manifest)
                if zip_bytes is None:
                    continue

                log(f"[pull] importing into {parent_title} ({parent_trilium_id}):")
                log_note_line(None, sync_id, note_title)
                result = client.import_zip(parent_trilium_id, zip_bytes, timeout=300)
                if result:
                    created_nid = result.get('note', {}).get('noteId', '?')
                    log("[pull] ✓ imported:")
                    log_note_line(created_nid, sync_id, note_title)
                else:
                    log("[pull] ⚠ import did not return cleanly:")
                    log_note_line(None, sync_id, note_title)
            except Exception as e:
                log(f"[pull] ✗ import failed: {e}")
                log_note_line(None, sync_id, note_title)
                continue

            all_created.append({"syncId": c["syncId"]})

        trilium_manifest = build_trilium_manifest(client, root_note_id)

    return all_created


def _dedup_entries_by_note_id(entries: list) -> None:
    """Remove duplicate entries with the same noteId, keeping the first occurrence.

    Trilium exports may include clone duplicates (same noteId, 1_-prefixed filenames).
    Recurses into children.
    """
    seen: set[str] = set()
    i = 0
    while i < len(entries):
        note_id = entries[i].get("noteId", "")
        if note_id and note_id in seen:
            entries.pop(i)
        else:
            if note_id:
                seen.add(note_id)
            if entries[i].get("children"):
                _dedup_entries_by_note_id(entries[i]["children"])
            i += 1


def _strip_clone_entries(entries: list) -> int:
    """Recursively remove all entries with isClone=true.

    These cause 'Missing parent note ID' errors during Trilium import
    because the referenced parent doesn't exist in the import context.
    Clones are reconciled separately after import via reconcile_clones.

    Returns count of entries removed.
    """
    removed = 0
    i = 0
    while i < len(entries):
        if entries[i].get("isClone"):
            entries.pop(i)
            removed += 1
        else:
            if entries[i].get("children"):
                removed += _strip_clone_entries(entries[i]["children"])
            i += 1
    return removed


def _build_sparse_import_zip(
    creates: list[dict[str, Any]],
    export_dir: Path,
    git_manifest: dict[str, Any],
) -> bytes | None:
    """Build a ZIP containing only the specified notes and their subtrees.

    Uses ImportZipBuilder to ensure Trilium-compatible output.
    """
    from .import_zip import ImportZipBuilder
    from .export import _sanitize_filename

    meta_path = export_dir / "!!!meta.json"
    if not meta_path.exists():
        return None
    full_meta = json.loads(meta_path.read_text())

    # Strip clone stubs and deduplicate entries by noteId.
    from .rewrite_ids import strip_clone_stubs
    strip_clone_stubs(full_meta)
    _dedup_entries_by_note_id(full_meta.get("files", []))

    root_entry = next((f for f in full_meta.get("files", []) if f.get("noteId") == "root"), None)
    root_dir = root_entry.get("dirFileName", "root") if root_entry else "root"

    entries_to_import: list[dict] = []
    for c in creates:
        sync_id = c["syncId"]
        entry = _find_entry_in_meta(full_meta, sync_id)
        if entry:
            if not entry.get("dataFileName") and not entry.get("dirFileName") and not entry.get("children"):
                continue
            entries_to_import.append(entry)
        else:
            git_note = c["gitNote"]
            entries_to_import.append({
                "noteId": sync_id,
                "title": git_note.get("title", "Untitled"),
                "type": git_note.get("type", "text"),
                "mime": git_note.get("mime", "text/html"),
                "format": git_note.get("format", "markdown"),
                "dataFileName": f"{git_note.get('title', 'note')}.md",
            })

    if not entries_to_import:
        return None

    _strip_clone_entries(entries_to_import)

    if not entries_to_import:
        return None

    # Determine base path in export directory
    first_sync_id = creates[0]["syncId"]
    first_git_note = git_manifest["notesBySyncId"].get(first_sync_id, {})
    content_path = first_git_note.get("contentPath", "")
    parent_path_in_export = ""
    if content_path:
        parts = content_path.split("/")
        if len(parts) > 1:
            # Content always lives inside its own dir now.
            # For README.md: <parent>/<dir>/README.md → parent_path = <parent>
            # For file notes: <parent>/<dir>/<file.ext> → parent_path = <parent>
            # In both cases, strip the last TWO components (dir + filename)
            if len(parts) > 2:
                parent_path_in_export = "/".join(parts[:-2])
            else:
                parent_path_in_export = ""
            if root_dir and parent_path_in_export.startswith(root_dir + "/"):
                parent_path_in_export = parent_path_in_export[len(root_dir) + 1:]
            elif parent_path_in_export == root_dir:
                parent_path_in_export = ""

    def _resolve_path(rel_path: str) -> Path:
        """Resolve a path relative to the export root dir."""
        if parent_path_in_export:
            return export_dir / root_dir / parent_path_in_export / rel_path
        return export_dir / root_dir / rel_path

    # Build using ImportZipBuilder
    builder = ImportZipBuilder()

    def _add_entry_to_builder(entry: dict, parent_note, parent_dir: str) -> None:
        """Recursively add a meta entry and its children to the builder."""
        title = entry.get("title", "Untitled")
        note_id = entry.get("noteId", "")
        note_type = entry.get("type", "text")
        mime = entry.get("mime", "text/html")
        # Only text notes use format; code/file notes have no format
        fmt = entry.get("format", "markdown" if note_type == "text" else "")
        position = entry.get("notePosition", 10)
        prefix = entry.get("prefix")
        is_expanded = entry.get("isExpanded", False)
        attributes = entry.get("attributes", [])

        # Ensure container notes have a content file
        data_filename = entry.get("dataFileName", "")
        if not data_filename and entry.get("dirFileName"):
            data_filename = f"{title}.md"
            fmt = "markdown"

        # Read content from disk using the ORIGINAL filename from meta
        dir_name = entry.get("dirFileName", "")
        # Content lives inside the note's own dir
        if dir_name:
            content_dir = f"{parent_dir}/{dir_name}" if parent_dir else dir_name
            content_file = _resolve_path(f"{content_dir}/{data_filename}")
        else:
            content_file = _resolve_path(f"{parent_dir}/{data_filename}" if parent_dir else data_filename)
        if content_file.exists() and content_file.is_file():
            content = content_file.read_bytes()
            # Skip LFS pointer files for binary notes — can't import without actual content
            if content.startswith(b"version https://git-lfs") and note_type in ("image", "file"):
                log("[pull] \u26a0 skipping LFS pointer (no actual content):")
                log_note_line(None, note_id, title)
                # Still recurse children
                dir_name = entry.get("dirFileName", "")
                child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
                for child_entry in entry.get("children", []):
                    if child_entry.get("isClone"):
                        continue
                    _add_entry_to_builder(child_entry, parent_note, child_dir)
                return
        else:
            content = f"# {title}\n".encode()

        # Create note — pass data_filename for file/image notes to preserve extension
        note_kwargs = dict(
            note_type=note_type, mime=mime, fmt=fmt,
            position=position, prefix=prefix,
            is_expanded=is_expanded, attributes=attributes,
        )
        if note_type in ("image", "file") and data_filename:
            note_kwargs["data_filename"] = data_filename

        if parent_note is None:
            note = builder.add_note(
                note_id, title, content,
                **note_kwargs,
            )
        else:
            note = builder.add_child(
                parent_note, note_id, title, content,
                **note_kwargs,
            )

        # Add attachments from meta
        # Attachments live in the note's own dir (same as README.md)
        att_base_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
        for att in entry.get("attachments", []):
            adf = att.get("dataFileName", "")
            if not adf:
                continue

            # Resolve attachment file path
            att_path = _resolve_path(f"{att_base_dir}/{adf}" if att_base_dir else adf)

            if not att_path.exists():
                log(f"[pull] \u26a0 attachment missing: {adf}")
                log_note_line(None, note_id, title)
                continue

            att_data = att_path.read_bytes()
            if not att_data:
                continue
            if att_data.startswith(b"version https://git-lfs"):
                log(f"[pull] \u26a0 attachment is LFS pointer: {adf}")
                log_note_line(None, note_id, title)
                continue

            att_filename = _sanitize_filename(Path(adf).name)

            try:
                builder.add_attachment(
                    note, att_filename, att_data,
                    title=att.get("title", att_filename),
                    role=att.get("role", ""),
                    mime=att.get("mime", ""),
                    position=att.get("position", 10),
                )
            except ValueError as e:
                log(f"[pull] \u26a0 skipping attachment {adf}: {e}")
                log_note_line(None, note_id, title)

        # Recurse children
        dir_name = entry.get("dirFileName", "")
        child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
        for child_entry in entry.get("children", []):
            if child_entry.get("isClone"):
                continue
            _add_entry_to_builder(child_entry, note, child_dir)

    for entry in entries_to_import:
        _add_entry_to_builder(entry, None, "")

    return builder.build()


# ---------------------------------------------------------------------------
# Update content
# ---------------------------------------------------------------------------

def apply_updates(
    client: TriliumClient,
    updates: list[dict[str, Any]],
    export_dir: Path,
) -> int:
    """Update changed notes in Trilium via ETAPI. Returns count of updates applied."""
    applied = 0
    for update in updates:
        trilium_note = update["triliumNote"]
        git_note = update["gitNote"]
        changes = update.get("changes", [])
        note_id = trilium_note["triliumNoteId"]

        if "title" in changes:
            client.patch_note(note_id, {"title": git_note["title"]})

        if "content" in changes:
            content_path = git_note.get("contentPath")
            if content_path:
                full_path = export_dir / content_path
                if full_path.exists() and full_path.is_file():
                    content = full_path.read_bytes()
                    if git_note.get("format") == "markdown" and git_note.get("type") == "text":
                        try:
                            text = content.decode("utf-8")
                            client.put_note_content(note_id, text, git_note.get("mime", "text/html"))
                        except UnicodeDecodeError:
                            client.put_note_content_bytes(note_id, content, git_note.get("mime", "application/octet-stream"))
                    else:
                        client.put_note_content_bytes(note_id, content, git_note.get("mime", "application/octet-stream"))

        if "attributes" in changes:
            _sync_attributes(client, note_id, git_note.get("attributes", []), trilium_note.get("attributes", []))

        applied += 1

    if applied:
        log(f"[pull] ✓ {applied} notes updated")
    return applied


def _sync_attributes(client: TriliumClient, note_id: str, git_attrs: list, trilium_attrs: list) -> None:
    """Sync attributes from git to Trilium (additive for now)."""
    existing = {(a["type"], a["name"], a.get("value", "")) for a in trilium_attrs}
    for attr in git_attrs:
        key = (attr.get("type", "label"), attr.get("name", ""), attr.get("value", ""))
        if key not in existing and attr.get("name") != SYNC_ID_ATTR:
            client.create_attribute({
                "noteId": note_id,
                "type": attr.get("type", "label"),
                "name": attr.get("name", ""),
                "value": attr.get("value", ""),
            })


# ---------------------------------------------------------------------------
# Delete notes
# ---------------------------------------------------------------------------

def apply_deletes(client: TriliumClient, deletes: list[dict[str, Any]]) -> int:
    """Delete notes from Trilium that are absent from git. Returns count."""
    deleted = 0
    for delete in deletes:
        trilium_note = delete["triliumNote"]
        note_id = trilium_note["triliumNoteId"]
        sync_id = delete["syncId"]
        title = trilium_note.get("title")
        reason = delete.get("reason")
        log("[pull] deleting:")
        log_note_line(note_id, sync_id, title, suffix=f"({reason})" if reason else "")
        client.delete_note(note_id)
        deleted += 1
    if deleted:
        log(f"[pull] ✓ {deleted} notes deleted")
    return deleted


# ---------------------------------------------------------------------------
# Move notes
# ---------------------------------------------------------------------------

def apply_moves(
    client: TriliumClient,
    moves: list[dict[str, Any]],
    trilium_manifest: dict[str, Any],
    root_note_id: str = "root",
) -> int:
    """Move notes to new parents by patching the branch. Returns count."""
    moved = 0
    for move in moves:
        trilium_note = move["triliumNote"]
        note_id = trilium_note["triliumNoteId"]
        sync_id = move["syncId"]
        title = trilium_note.get("title")
        old_parent_id = trilium_note.get("parentTriliumNoteId", "")
        new_parent_sync_id = move["newParentSyncId"]
        # ``"root"`` is the synthetic parent for top-level notes and
        # isn't in ``notesBySyncId`` (the configured root has no gitSyncId
        # label); map it onto the configured root's Trilium id.
        if new_parent_sync_id == "root":
            new_parent_id = root_note_id
        else:
            new_parent = trilium_manifest["notesBySyncId"].get(new_parent_sync_id)
            if not new_parent:
                log(f"[pull] ⚠ move skipped: parent syncId={new_parent_sync_id} not found:")
                log_note_line(note_id, sync_id, title)
                continue
            new_parent_id = new_parent["triliumNoteId"]
        branch_id = f"{old_parent_id}_{note_id}"
        log(f"[pull] moving → parent={new_parent_id}:")
        log_note_line(note_id, sync_id, title)
        try:
            client.patch_branch(branch_id, {"parentNoteId": new_parent_id})
            moved += 1
        except Exception as e:
            log(f"[pull] ⚠ move failed: {e}")
            log_note_line(note_id, sync_id, title)
    if moved:
        log(f"[pull] ✓ {moved} notes moved")
    return moved


# ---------------------------------------------------------------------------
# Full pull apply
# ---------------------------------------------------------------------------

def apply_pull_plan(
    client: TriliumClient,
    plan: dict[str, Any],
    export_dir: Path,
    git_manifest: dict[str, Any],
    trilium_manifest: dict[str, Any],
    root_note_id: str = "root",
) -> dict[str, Any]:
    """Apply the full pull plan. Returns summary of actions taken."""
    results: dict[str, Any] = {"tagged": 0, "created": 0, "updated": 0, "deleted": 0, "moved": 0, "clones_created": 0, "clones_removed": 0}

    update_sync_ids = {u["syncId"] for u in plan.get("updates", [])}

    # 1. Moves (only for notes NOT being updated)
    moves_to_apply = [m for m in plan.get("moves", []) if m["syncId"] not in update_sync_ids]
    if moves_to_apply:
        log(f"[pull] moving {len(moves_to_apply)} note(s):")
        for m in moves_to_apply:
            tnote = m.get("triliumNote", {})
            log_note_line(
                tnote.get("triliumNoteId"),
                m["syncId"],
                m["gitNote"].get("title"),
                marker="↔",
                suffix=f"{m['oldParentSyncId']} → {m['newParentSyncId']}",
            )
    results["moved"] = apply_moves(client, moves_to_apply, trilium_manifest, root_note_id)

    # 2. Deletes
    plan_deletes = plan.get("deletes", [])
    if plan_deletes:
        log(f"[pull] deleting {len(plan_deletes)} note(s):")
        for d in plan_deletes:
            tnote = d["triliumNote"]
            log_note_line(tnote.get("triliumNoteId"), d["syncId"], tnote.get("title"))
    results["deleted"] = apply_deletes(client, plan_deletes)

    # 3. Combine updates + creates into a single import batch
    updates = plan.get("updates", [])
    plan_creates = list(plan.get("creates", []))
    if plan_creates:
        log(f"[pull] creating {len(plan_creates)} note(s):")
        for c in plan_creates:
            log_note_line(None, c["syncId"], c["gitNote"].get("title"), marker="+")
    if updates:
        log(f"[pull] updating {len(updates)} notes (delete+reimport):")
        for update in updates:
            tnote = update.get("triliumNote", {})
            changes = ", ".join(update.get("changes", []))
            log_note_line(
                tnote.get("triliumNoteId"),
                update["syncId"],
                update["gitNote"].get("title"),
                marker="~",
                suffix=f"[{changes}]" if changes else "",
            )
        for update in updates:
            tnote = update["triliumNote"]
            note_id = tnote["triliumNoteId"]
            try:
                client.delete_note(note_id)
            except Exception as e:
                log(f"[pull] ⚠ failed to delete for update: {e}")
                log_note_line(note_id, update["syncId"], update["gitNote"].get("title"))
        results["updated"] = len(updates)
        plan_creates.extend({"syncId": u["syncId"], "gitNote": u["gitNote"], "reason": "updated"} for u in updates)

    # 4. Import all
    if plan_creates:
        trilium_manifest = build_trilium_manifest(client, root_note_id)

        git_notes = git_manifest["notesBySyncId"]

        def note_depth(c: dict) -> int:
            depth = 0
            sid = c.get("gitNote", {}).get("parentSyncId")
            while sid and sid in git_notes and depth < 50:
                depth += 1
                sid = git_notes[sid].get("parentSyncId")
            return depth

        plan_creates.sort(key=note_depth)
        created = apply_creates(client, plan_creates, export_dir, git_manifest, trilium_manifest, root_note_id)
        results["created"] = len(created)

    # 5. Post-import tagging
    if plan_creates:
        log("[tag] re-scanning for untagged notes")
        new_manifest = build_trilium_manifest(client, root_note_id)
        results["tagged"] = tag_all_untagged(client, new_manifest, git_manifest, root_note_id)

    # 6. Reconcile clones
    clones_result = reconcile_clones(client, git_manifest, root_note_id)
    results["clones_created"] = clones_result["created"]
    results["clones_removed"] = clones_result["removed"]

    log(f"[pull] ✓ complete: +{results['created']} ~{results['updated']} -{results['deleted']} ↔{results['moved']} tagged={results['tagged']} clones=+{results['clones_created']}/-{results['clones_removed']}")
    return results


# ---------------------------------------------------------------------------
# Clone reconciliation
# ---------------------------------------------------------------------------

def reconcile_clones(client: TriliumClient, git_manifest: dict, root_note_id: str) -> dict[str, int]:
    """Reconcile clone (multi-parent) branches between git manifest and Trilium."""
    result = {"created": 0, "removed": 0}
    git_notes = git_manifest["notesBySyncId"]

    notes_with_clones = {sid: n for sid, n in git_notes.items() if n.get("cloneParentSyncIds")}
    if not notes_with_clones:
        return result

    trilium_manifest = build_trilium_manifest(client, root_note_id)
    notes_by_sync_id = trilium_manifest["notesBySyncId"]
    notes_by_trilium_id = trilium_manifest["notesByTriliumId"]

    # Build syncId → triliumNoteId lookup
    sync_to_trilium: dict[str, str] = {}
    for nid, entry in notes_by_trilium_id.items():
        sid = entry.get("syncId")
        if sid:
            sync_to_trilium[sid] = nid

    for sync_id, git_note in notes_with_clones.items():
        note_trilium_id = sync_to_trilium.get(sync_id)
        if not note_trilium_id:
            continue

        trilium_entry = notes_by_trilium_id.get(note_trilium_id)
        if not trilium_entry:
            continue

        # Parse cloneParentSyncIds (list of {syncId, prefix, notePosition} dicts or plain strings)
        raw_clone_parents = git_note.get("cloneParentSyncIds", [])
        desired_map: dict[str, dict] = {}  # triliumNoteId → {prefix, notePosition}
        for item in raw_clone_parents:
            if isinstance(item, dict):
                psid = item.get("syncId", "")
                prefix = item.get("prefix")
                note_position = item.get("notePosition")
            else:
                psid = item
                prefix = None
                note_position = None
            ptid = root_note_id if psid == "root" else sync_to_trilium.get(psid)
            if ptid:
                desired_map[ptid] = {"prefix": prefix, "notePosition": note_position}

        current_all_parents = set(trilium_entry.get("allParentNoteIds", []))
        canonical_parent = trilium_entry.get("parentTriliumNoteId")
        current_clone_parents = current_all_parents - {canonical_parent}

        # Create missing clones
        to_create = set(desired_map.keys()) - current_clone_parents
        for parent_id in to_create:
            try:
                branch_body: dict[str, Any] = {"noteId": note_trilium_id, "parentNoteId": parent_id}
                info = desired_map.get(parent_id, {})
                if info.get("prefix"):
                    branch_body["prefix"] = info["prefix"]
                if info.get("notePosition") is not None:
                    branch_body["notePosition"] = info["notePosition"]
                client.create_branch(branch_body)
                parent_title = notes_by_trilium_id.get(parent_id, {}).get("title", "?")
                note_title = trilium_entry.get("title")
                prefix_display = f" [{info.get('prefix')}]" if info.get("prefix") else ""
                log(f"[clone] created → {parent_title}{prefix_display}:")
                log_note_line(note_trilium_id, sync_id, note_title)
                result["created"] += 1
            except Exception as e:
                log(f"[clone] ⚠ failed to create branch: {sync_id} → {parent_id}: {e}")

        # Remove extra clones
        to_remove = current_clone_parents - set(desired_map.keys())
        for parent_id in to_remove:
            branch_id = f"{parent_id}_{note_trilium_id}"
            try:
                client.delete_branch(branch_id)
                parent_title = notes_by_trilium_id.get(parent_id, {}).get("title", "?")
                note_title = trilium_entry.get("title")
                log(f"[clone] removed → {parent_title}:")
                log_note_line(note_trilium_id, sync_id, note_title)
                result["removed"] += 1
            except Exception as e:
                log(f"[clone] ⚠ failed to remove branch {branch_id}: {e}")

    return result


# ---------------------------------------------------------------------------
# Full import (fresh clone or no local state)
# ---------------------------------------------------------------------------

def apply_full_import(client: TriliumClient, export_dir: Path, root_note_id: str) -> None:
    """Import git notes into Trilium. Deduplicates by gitSyncId."""
    git_manifest = build_git_manifest(export_dir)
    git_notes = git_manifest["notesBySyncId"]
    if not git_notes:
        log("[pull] git export is empty")
        return

    trilium_manifest = build_trilium_manifest(client, root_note_id)
    existing_sync_ids = set(trilium_manifest["notesBySyncId"].keys())

    to_create = {sid: n for sid, n in git_notes.items() if sid not in existing_sync_ids}
    if not to_create:
        log("[pull] all notes already in Trilium → skip")
        return

    log(f"[pull] importing {len(to_create)} notes ({len(existing_sync_ids)} existing):")
    creates = [{"syncId": sid, "gitNote": n} for sid, n in to_create.items()]
    log_note_lines(_git_create_descriptor(c) for c in creates)

    created = apply_creates(client, creates, export_dir, git_manifest, trilium_manifest, root_note_id)

    if created:
        log("[tag] tagging imported notes")
        trilium_manifest = build_trilium_manifest(client, root_note_id)
        tagged = tag_all_untagged(client, trilium_manifest, git_manifest, root_note_id)
        log(f"[tag] ✓ {tagged} notes tagged")

    # Reconcile clones
    clones_result = reconcile_clones(client, git_manifest, root_note_id)
    if clones_result["created"] or clones_result["removed"]:
        log(f"[clone] +{clones_result['created']} -{clones_result['removed']} clone branches reconciled")
