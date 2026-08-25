"""ID rewriting: noteId↔syncId transformations in meta and content files.

Handles:
- Rewriting Trilium noteIds to stable gitSyncIds in exported meta+content
- Injecting cloneParentSyncIds for multi-parent notes
- Stripping clone stubs from meta tree
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from .client import TriliumClient
from .common import ensure_dir, log, META_FILE_NAME
from .manifest import SYNC_ID_ATTR, build_id_map, build_trilium_manifest
from .meta_tree import find_entry_by_sync_id, find_note_path_in_meta, walk_entries


# ---------------------------------------------------------------------------
# ID rewriting (export direction: Trilium noteIds → gitSyncIds)
# ---------------------------------------------------------------------------

def rewrite_meta_with_sync_ids(client: TriliumClient, export_root: Path, root_note_id: str) -> None:
    """Rewrite !!!meta.json and content files: replace Trilium noteIds with gitSyncId values.
    Also tag any untagged notes with a new gitSyncId first."""
    meta_path = export_root / META_FILE_NAME
    if not meta_path.exists():
        return

    from .apply import tag_note_with_sync_id

    trilium_manifest = build_trilium_manifest(client, root_note_id)
    notes_by_id = trilium_manifest["notesByTriliumId"]
    untagged = trilium_manifest["untagged"]

    # Tag any untagged notes with their own triliumNoteId
    for note in untagged:
        nid = note["triliumNoteId"]
        if nid == root_note_id:
            continue
        tag_note_with_sync_id(client, nid, nid)
        notes_by_id[nid]["syncId"] = nid

    # Build triliumNoteId → syncId map
    id_map = build_id_map(notes_by_id)

    # Rewrite the meta
    meta = json.loads(meta_path.read_text())
    rewrite_ids_in_entries(meta.get("files", []), id_map)

    # Inject cloneParentSyncIds for notes that have multiple parents (clones)
    sync_id_to_entry: dict[str, dict] = {}
    for nid, te in notes_by_id.items():
        sid = id_map.get(nid)
        if sid:
            sync_id_to_entry[sid] = te
    inject_clone_parent_ids(meta.get("files", []), sync_id_to_entry, id_map)

    # Remove clone stub entries (duplicates without content)
    stubs_removed = strip_clone_stubs(meta, export_dir=export_root)
    if stubs_removed:
        log(f"[push] stripped {stubs_removed} clone stub(s) from meta")

    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")

    # Generate clone pointer files
    generate_clone_pointer_files(export_root, meta)

    # Rewrite content files
    rewrite_ids_in_content(export_root, id_map)

    log(f"[push] rewrote {len(id_map)} IDs in meta+content")


def rewrite_ids_in_entries(entries: list, id_map: dict[str, str]) -> None:
    """Recursively replace noteId fields with syncId equivalents."""
    for entry in entries:
        note_id = entry.get("noteId", "")
        if note_id and note_id in id_map:
            entry["noteId"] = id_map[note_id]

        if entry.get("notePath"):
            entry["notePath"] = [id_map.get(p, p) for p in entry["notePath"]]

        for attr in entry.get("attributes", []):
            if attr.get("type") == "relation" and attr.get("value") in id_map:
                attr["value"] = id_map[attr["value"]]

        if entry.get("children"):
            rewrite_ids_in_entries(entry["children"], id_map)


def inject_clone_parent_ids(entries: list, sync_id_to_entry: dict, id_map: dict[str, str]) -> None:
    """Walk meta entries and add cloneParentSyncIds for notes with multiple parents."""
    for entry in entries:
        sync_id = entry.get("noteId", "")
        trilium_entry = sync_id_to_entry.get(sync_id)

        if trilium_entry:
            all_parents = trilium_entry.get("allParentNoteIds", [])
            canonical_parent = trilium_entry.get("parentTriliumNoteId")
            clone_parents = [pid for pid in all_parents if pid != canonical_parent]
            if clone_parents:
                clone_branches = trilium_entry.get("cloneBranches", [])
                branch_info_by_parent: dict[str, dict] = {}
                for cb in clone_branches:
                    branch_info_by_parent[cb["parentNoteId"]] = cb

                clone_entries = []
                for pid in clone_parents:
                    psid = id_map.get(pid, pid)
                    info = branch_info_by_parent.get(pid, {})
                    clone_entries.append({
                        "syncId": psid,
                        "prefix": info.get("prefix"),
                        "notePosition": info.get("notePosition"),
                    })
                entry["cloneParentSyncIds"] = sorted(clone_entries, key=lambda x: x["syncId"])
            else:
                entry.pop("cloneParentSyncIds", None)
        else:
            entry.pop("cloneParentSyncIds", None)

        if entry.get("children"):
            inject_clone_parent_ids(entry["children"], sync_id_to_entry, id_map)


def strip_clone_stubs(meta: dict, export_dir: Path | None = None) -> int:
    """Remove clone stub entries from the meta tree.

    A clone stub is an entry whose noteId appears elsewhere in the tree
    with actual content (has dataFileName or dirFileName). The canonical
    entry keeps cloneParentSyncIds as the authoritative clone record.

    When ``export_dir`` is given, also removes on-disk files that
    belonged to stripped content-duplicate entries (full-content clones
    that Trilium placed at a second parent location).

    Returns count of stubs removed.
    """
    # Pre-pass: collect paths of duplicate entries so we can clean up
    # their on-disk files after removal from meta.
    dup_paths: list[tuple[str, dict]] = []  # (parent_dir, entry)
    if export_dir is not None:
        _collect_dup_paths(meta.get("files", []), "", set(), dup_paths)

    canonical_ids = _collect_canonical_ids(meta)
    removed = _remove_stubs(meta.get("files", []), canonical_ids)

    # Clean up on-disk files for stripped content duplicates.
    if export_dir is not None:
        for parent_dir, entry in dup_paths:
            dir_name = entry.get("dirFileName", "")
            if dir_name:
                dup_dir = (export_dir / parent_dir / dir_name) if parent_dir else (export_dir / dir_name)
                if dup_dir.is_dir():
                    import shutil
                    shutil.rmtree(dup_dir)
            data_file = entry.get("dataFileName", "")
            if data_file and not dir_name:
                dup_file = (export_dir / parent_dir / data_file) if parent_dir else (export_dir / data_file)
                if dup_file.exists():
                    dup_file.unlink()

    return removed


def _collect_dup_paths(
    entries: list, parent_dir: str, seen: set[str],
    out: list[tuple[str, dict]],
) -> None:
    """Walk the meta tree and record (parent_dir, entry) for duplicate noteIds."""
    for entry in entries:
        note_id = entry.get("noteId", "")
        if note_id == "root":
            child_dir = entry.get("dirFileName", "") or parent_dir
            if entry.get("children"):
                _collect_dup_paths(entry["children"], child_dir, seen, out)
            continue
        if note_id:
            if note_id in seen:
                out.append((parent_dir, entry))
            else:
                seen.add(note_id)
        dir_name = entry.get("dirFileName", "")
        child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
        if entry.get("children"):
            _collect_dup_paths(entry["children"], child_dir, seen, out)


def _collect_canonical_ids(meta: dict) -> set[str]:
    """Collect noteIds of entries that have actual content."""
    canonical_ids: set[str] = set()
    for ctx in walk_entries(meta):
        entry = ctx["entry"]
        note_id = entry.get("noteId")
        if note_id and (entry.get("dataFileName") or entry.get("dirFileName")):
            canonical_ids.add(note_id)
    return canonical_ids


def _remove_stubs(entries: list, canonical_ids: set[str], seen: set[str] | None = None) -> int:
    """Remove entries that are clone stubs or duplicate full-content clones.

    A clone stub is an entry whose ``noteId`` already appeared elsewhere
    with actual content — typically bare entries (no ``dataFileName``, no
    ``dirFileName``) produced by Trilium's full-tree export.

    A *content duplicate* is a second (or later) entry for the same
    ``noteId`` that also has real content. Trilium's subtree export can
    place the full note content under every parent, producing multiple
    entries that all look canonical. ``strip_clone_stubs`` is always
    called *after* ``inject_clone_parent_ids`` has recorded the clone
    parents on the first-seen entry, so removing later duplicates is
    safe — ``generate_clone_pointer_files`` will produce a pointer .md
    file for each clone parent listed in ``cloneParentSyncIds``.
    """
    if seen is None:
        seen = set()
    removed = 0
    i = 0
    while i < len(entries):
        entry = entries[i]
        note_id = entry.get("noteId")
        is_bare_stub = (
            note_id
            and note_id in canonical_ids
            and not entry.get("dataFileName")
            and not entry.get("dirFileName")
        )
        # Duplicate full-content entry: the first-seen canonical is
        # already in *seen*; every subsequent occurrence is a clone
        # placement that should become a pointer file.
        is_content_dup = (
            note_id
            and not is_bare_stub
            and note_id in seen
        )
        if is_bare_stub or is_content_dup:
            entries.pop(i)
            removed += 1
        else:
            if note_id:
                seen.add(note_id)
            if entry.get("children"):
                removed += _remove_stubs(entry["children"], canonical_ids, seen)
            i += 1
    return removed


def rewrite_ids_in_content(export_root: Path, id_map: dict[str, str]) -> None:
    """Scan content files and replace Trilium noteIds with gitSyncIds."""
    replacements = {k: v for k, v in id_map.items() if k != v}
    if not replacements:
        return

    id_pattern = re.compile(
        r'(?<=data-note-id=")(' + '|'.join(re.escape(k) for k in replacements) + r')(?=")'
        r'|(?<=#root/)(' + '|'.join(re.escape(k) for k in replacements) + r')(?=[/"\s])'
        r'|(?<=noteId=)(' + '|'.join(re.escape(k) for k in replacements) + r')(?=[&"\s])'
    )

    def replace_match(m: re.Match) -> str:
        matched = m.group(0)
        return replacements.get(matched, matched)

    count = 0
    for file in export_root.rglob("*"):
        if not file.is_file():
            continue
        if file.suffix not in (".md", ".html", ".htm", ".json"):
            continue
        if file.name == "!!!meta.json":
            continue
        try:
            content = file.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        new_content = id_pattern.sub(replace_match, content)
        if new_content != content:
            file.write_text(new_content, encoding="utf-8")
            count += 1

    if count:
        log(f"[push] rewrote IDs in {count} content files")


# ---------------------------------------------------------------------------
# Clone pointer file generation
# ---------------------------------------------------------------------------

def generate_clone_pointer_files(export_root: Path, meta: dict) -> tuple[int, set[str]]:
    """Generate pointer .md files for clone placements.

    For notes with multiple parents (clones), generates short .md pointer files
    under each clone parent's directory with a relative link to the canonical location.

    Returns (count of pointer files written, set of relative directory paths created).
    """
    # Collect clone info: walk meta for entries with cloneParentSyncIds
    clones = _collect_clones(meta)

    if not clones:
        return 0, set()

    count = 0
    touched_dirs: set[str] = set()
    for clone_info in clones:
        sync_id = clone_info["syncId"]
        title = clone_info["title"]
        clone_parent_entries = clone_info["cloneParentSyncIds"]

        canonical_path_info = find_note_path_in_meta(meta, sync_id)
        canonical_entry = find_entry_by_sync_id(meta, sync_id)
        if not canonical_path_info or not canonical_entry:
            continue

        canonical_parent_dir, _ = canonical_path_info
        canonical_data_file = canonical_entry.get("dataFileName", "")
        if not canonical_data_file:
            continue
        # When dataFileName is README.md, it lives inside the note's own dir
        canonical_dir_name = canonical_entry.get("dirFileName", "")
        if canonical_data_file == "README.md" and canonical_dir_name:
            content_dir = f"{canonical_parent_dir}/{canonical_dir_name}" if canonical_parent_dir else canonical_dir_name
            canonical_path = f"{content_dir}/{canonical_data_file}"
        else:
            canonical_path = f"{canonical_parent_dir}/{canonical_data_file}" if canonical_parent_dir else canonical_data_file

        for clone_parent_item in clone_parent_entries:
            if isinstance(clone_parent_item, dict):
                clone_parent_sid = clone_parent_item.get("syncId", "")
                prefix = clone_parent_item.get("prefix")
            else:
                clone_parent_sid = clone_parent_item
                prefix = None

            parent_path_info = find_note_path_in_meta(meta, clone_parent_sid)
            parent_entry = find_entry_by_sync_id(meta, clone_parent_sid)
            if not parent_entry:
                continue

            parent_dir_name = parent_entry.get("dirFileName", "")
            if parent_path_info:
                pp_dir, _ = parent_path_info
                clone_parent_dir = f"{pp_dir}/{parent_dir_name}" if pp_dir and parent_dir_name else (parent_dir_name or pp_dir)
            else:
                clone_parent_dir = parent_dir_name

            if not clone_parent_dir:
                continue

            pointer_dir_name = _make_pointer_dirname(title, prefix)
            rel_link = _relative_link(f"{clone_parent_dir}/{pointer_dir_name}", canonical_path)

            pointer_dir = export_root / clone_parent_dir / pointer_dir_name
            ensure_dir(pointer_dir)
            pointer_path = pointer_dir / "README.md"
            display_title = f"{prefix} - {title}" if prefix else title
            pointer_path.write_text(f"See [{display_title}]({rel_link})\n")
            # Track both the clone parent dir and the pointer dir so
            # incremental sparse commits include these sections.
            touched_dirs.add(clone_parent_dir)
            pointer_rel = f"{clone_parent_dir}/{pointer_dir_name}"
            touched_dirs.add(pointer_rel)
            count += 1

    if count:
        log(f"[push] generated {count} clone pointer file(s)")
    return count, touched_dirs


def _collect_clones(meta: dict) -> list[dict]:
    """Walk meta entries and collect clone info using walk_entries."""
    result: list[dict] = []
    for ctx in walk_entries(meta):
        entry = ctx["entry"]
        note_id = entry.get("noteId", "")
        clone_parents = entry.get("cloneParentSyncIds", [])
        if clone_parents and note_id:
            result.append({
                "syncId": note_id,
                "title": entry.get("title", "Untitled"),
                "cloneParentSyncIds": clone_parents,
            })
    return result


def _make_pointer_dirname(title: str, prefix: str | None) -> str:
    """Build sanitized directory name for a clone pointer."""
    name = f"{prefix} - {title}" if prefix else title
    name = re.sub(r'[<>:"/\\|?*]', '_', name)
    name = re.sub(r'\s+', '_', name)
    name = name.strip('_.')
    if not name:
        name = "clone"
    return name


def _relative_link(from_dir: str, to_path: str) -> str:
    """Compute a relative path from from_dir to to_path."""
    from_parts = [p for p in from_dir.split('/') if p]
    to_parts = [p for p in to_path.split('/') if p]

    common = 0
    for a, b in zip(from_parts, to_parts):
        if a == b:
            common += 1
        else:
            break

    ups = len(from_parts) - common
    remainder = to_parts[common:]
    parts = ['..'] * ups + remainder
    return '/'.join(parts) if parts else to_path
