"""Meta-tree navigation and manipulation.

Provides a unified depth-first walker over the !!!meta.json tree structure
and higher-level operations built on it (find, insert, remove, move).
"""
from __future__ import annotations

from typing import Any, Generator


# ---------------------------------------------------------------------------
# Unified walker
# ---------------------------------------------------------------------------

def walk_entries(
    meta: dict,
    *,
    _entries: list | None = None,
    _parent_entry: dict | None = None,
    _parent_dir: str = "",
    _parent_sync_id: str | None = None,
) -> Generator[dict[str, Any], None, None]:
    """Depth-first walk yielding context dicts for every entry.

    Each yielded dict contains:
        entry          - the entry dict itself
        parent_entry   - parent entry (None for top-level)
        parent_dir     - accumulated directory path to this entry's parent
        parent_sync_id - noteId of the parent entry
        index          - position within parent's children list
        siblings       - the list containing this entry (for mutation)
    """
    entries = _entries if _entries is not None else meta.get("files", [])

    for i, entry in enumerate(entries):
        note_id = entry.get("noteId", "")

        # Root wrapper — recurse with root's dirFileName as parent_dir.
        # Pass the root's own noteId ("root") as parent_sync_id for its
        # children so :func:`find_parent_sync_id_in_meta` can distinguish
        # a top-level note (parent == "root") from one missing from meta
        # (returns None). Without this, :func:`detect_export_moves` cannot
        # detect a move whose old parent was the root note.
        if note_id == "root":
            root_dir = entry.get("dirFileName", "root")
            if entry.get("children"):
                yield from walk_entries(
                    meta,
                    _entries=entry["children"],
                    _parent_entry=entry,
                    _parent_dir=root_dir,
                    _parent_sync_id=note_id,
                )
            continue

        yield {
            "entry": entry,
            "parent_entry": _parent_entry,
            "parent_dir": _parent_dir,
            "parent_sync_id": _parent_sync_id,
            "index": i,
            "siblings": entries,
        }

        dir_name = entry.get("dirFileName", "")
        child_dir = f"{_parent_dir}/{dir_name}" if _parent_dir and dir_name else (dir_name or _parent_dir)
        if entry.get("children"):
            yield from walk_entries(
                meta,
                _entries=entry["children"],
                _parent_entry=entry,
                _parent_dir=child_dir,
                _parent_sync_id=note_id,
            )


# ---------------------------------------------------------------------------
# Query operations
# ---------------------------------------------------------------------------

def find_entry_by_sync_id(meta: dict, sync_id: str) -> dict | None:
    """Find a note entry in the meta tree by its noteId (syncId) field."""
    for ctx in walk_entries(meta):
        if ctx["entry"].get("noteId") == sync_id:
            return ctx["entry"]
    return None


def find_note_path_in_meta(meta: dict, sync_id: str) -> tuple[str, int] | None:
    """Find a note's (parent_dir, index) in the meta tree."""
    for ctx in walk_entries(meta):
        if ctx["entry"].get("noteId") == sync_id:
            return (ctx["parent_dir"], ctx["index"])
    return None


def find_parent_sync_id_in_meta(meta: dict, sync_id: str) -> str | None:
    """Find the parent's noteId for a given note."""
    for ctx in walk_entries(meta):
        if ctx["entry"].get("noteId") == sync_id:
            return ctx["parent_sync_id"]
    return None


# ---------------------------------------------------------------------------
# Mutation operations
# ---------------------------------------------------------------------------

def remove_entry_from_meta(meta: dict, sync_id: str) -> dict | None:
    """Remove an entry from the meta tree. Returns the removed entry."""
    for ctx in walk_entries(meta):
        if ctx["entry"].get("noteId") == sync_id:
            return ctx["siblings"].pop(ctx["index"])
    return None


def insert_entry_into_meta(meta: dict, parent_sync_id: str, entry: dict) -> bool:
    """Insert an entry as a child of the given parent."""
    # Check root-level entries first
    files = meta.get("files", [])
    for e in files:
        if e.get("noteId") == parent_sync_id:
            if "children" not in e:
                e["children"] = []
            e["children"].append(entry)
            return True

    # Walk the tree
    for ctx in walk_entries(meta):
        if ctx["entry"].get("noteId") == parent_sync_id:
            if "children" not in ctx["entry"]:
                ctx["entry"]["children"] = []
            ctx["entry"]["children"].append(entry)
            return True
    return False


def splice_meta_entry(meta: dict, sync_id: str, parent_dir: str, new_entry: dict) -> None:
    """Replace an entry in the meta tree with an updated one."""
    for ctx in walk_entries(meta):
        if ctx["entry"].get("noteId") == sync_id:
            ctx["siblings"][ctx["index"]] = new_entry
            return
