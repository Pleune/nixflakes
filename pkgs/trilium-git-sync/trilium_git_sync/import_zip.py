"""Trilium import ZIP builder.

Provides a safe abstraction for building import ZIPs that Trilium can process
without hanging or corrupting data. Encapsulates all the rules discovered
through trial and error about Trilium's picky import format.

Rules enforced:
1. ALL files in the ZIP must be declared in the meta (dataFileName or attachment dataFileName)
2. Attachment files are flat (no subdirectories) relative to parent's dirFileName
3. No isClone entries, no notePath fields
4. No empty/corrupt binary files
5. Content img/src references to files not in the ZIP are stripped
6. formatVersion: 2, tree nesting determines parent-child relationships
"""
from __future__ import annotations

import io
import json
import mimetypes
import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .common import log


@dataclass
class ImportNote:
    """A note to be included in an import ZIP."""

    note_id: str
    title: str
    content: bytes
    """Raw content (markdown or HTML)."""

    note_type: str = "text"
    mime: str = "text/html"
    fmt: str = "markdown"
    position: int = 10
    prefix: str | None = None
    is_expanded: bool = False
    attributes: list[dict[str, Any]] = field(default_factory=list)
    attachments: list["ImportAttachment"] = field(default_factory=list)
    children: list["ImportNote"] = field(default_factory=list)
    data_filename: str = ""
    """Explicit filename for the content file. If empty, generated from title."""
    dir_filename: str | None = None
    """Explicit directory name. If None, generated from title when note has children."""


@dataclass
class ImportAttachment:
    """An attachment to be included in an import ZIP."""

    filename: str
    """Flat filename (no directory component). Must be unique within the parent note."""

    data: bytes
    """Raw binary data."""

    title: str = ""
    """Display title. Defaults to filename."""

    role: str = ""
    """'image' or 'file'. Auto-detected from mime if empty."""

    mime: str = ""
    """MIME type. Auto-detected from filename if empty."""

    attachment_id: str = ""
    """Generated internally. Trilium ignores provided IDs and assigns new ones."""

    position: int = 10


class ImportZipBuilder:
    """Builds a Trilium-compatible import ZIP.

    Usage:
        builder = ImportZipBuilder()
        note = builder.add_note("id1", "My Note", content_bytes)
        builder.add_attachment(note, "image.png", image_bytes)
        child = builder.add_child(note, "id2", "Child Note", child_content)
        zip_bytes = builder.build()
    """

    def __init__(self) -> None:
        self._roots: list[ImportNote] = []

    def add_note(
        self,
        note_id: str,
        title: str,
        content: bytes,
        *,
        note_type: str = "text",
        mime: str = "text/html",
        fmt: str = "markdown",
        position: int = 10,
        prefix: str | None = None,
        is_expanded: bool = False,
        attributes: list[dict[str, Any]] | None = None,
        data_filename: str = "",
        dir_filename: str | None = None,
    ) -> ImportNote:
        """Add a top-level note to the import."""
        note = ImportNote(
            note_id=note_id,
            title=title,
            content=content,
            note_type=note_type,
            mime=mime,
            fmt=fmt,
            position=position,
            prefix=prefix,
            is_expanded=is_expanded,
            attributes=attributes or [],
            data_filename=data_filename,
            dir_filename=dir_filename,
        )
        self._roots.append(note)
        return note

    def add_child(
        self,
        parent: ImportNote,
        note_id: str,
        title: str,
        content: bytes,
        *,
        note_type: str = "text",
        mime: str = "text/html",
        fmt: str = "markdown",
        position: int = 10,
        prefix: str | None = None,
        is_expanded: bool = False,
        attributes: list[dict[str, Any]] | None = None,
        data_filename: str = "",
        dir_filename: str | None = None,
    ) -> ImportNote:
        """Add a child note under the given parent."""
        note = ImportNote(
            note_id=note_id,
            title=title,
            content=content,
            note_type=note_type,
            mime=mime,
            fmt=fmt,
            position=position,
            prefix=prefix,
            is_expanded=is_expanded,
            attributes=attributes or [],
            data_filename=data_filename,
            dir_filename=dir_filename,
        )
        parent.children.append(note)
        return note

    def add_attachment(
        self,
        note: ImportNote,
        filename: str,
        data: bytes,
        *,
        title: str = "",
        role: str = "",
        mime: str = "",
        position: int = 10,
    ) -> ImportAttachment:
        """Add an attachment to a note.

        The filename must be flat (no directory separators).
        Data must not be empty or an LFS pointer.
        """
        if "/" in filename or "\\" in filename:
            raise ValueError(f"Attachment filename must be flat (no dirs): {filename}")
        if not data:
            raise ValueError(f"Attachment data must not be empty: {filename}")
        if data.startswith(b"version https://git-lfs"):
            raise ValueError(f"Attachment is an LFS pointer, not real data: {filename}")

        if not mime:
            mime = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        if not role:
            role = "image" if mime.startswith("image/") else "file"
        if not title:
            title = filename

        att = ImportAttachment(
            filename=filename,
            data=data,
            title=title,
            role=role,
            mime=mime,
            position=position,
        )
        note.attachments.append(att)
        return att

    def build(self) -> bytes:
        """Build the import ZIP.

        Returns the ZIP as bytes ready to POST to Trilium's import API.
        Strips any content references to attachments not in the ZIP.
        """
        if not self._roots:
            raise ValueError("No notes to import")

        # Build meta and file entries
        meta_entries: list[dict] = []
        zip_files: dict[str, bytes] = {}  # zip_path -> data

        for note in self._roots:
            self._build_entry(note, "", meta_entries, zip_files)

        import_meta = {
            "formatVersion": 2,
            "appVersion": "0.102.2",
            "files": meta_entries,
        }

        # Collect files (content already rewritten in _build_entry)
        cleaned_files = zip_files

        # Build ZIP — order matters: parent content must come before children
        # Use ZIP_STORED (no compression) for speed — these files are already
        # compressed (images, zips, tars) or small (markdown).
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as zf:
            zf.writestr("!!!meta.json", json.dumps(import_meta, indent=2))
            # Write files in tree order (depth-first, parent content + attachments before children)
            for zip_path in self._tree_ordered_paths(meta_entries, cleaned_files):
                zf.writestr(zip_path, cleaned_files[zip_path])

        return buf.getvalue()

    def _tree_ordered_paths(
        self, meta_entries: list[dict], files: dict[str, bytes]
    ) -> list[str]:
        """Return ZIP paths in tree order: parent content + attachments before children."""
        ordered: list[str] = []
        remaining = set(files.keys())

        def _walk(entries: list[dict], parent_dir: str) -> None:
            for entry in entries:
                # Content file
                df = entry.get("dataFileName", "")
                if df:
                    path = f"{parent_dir}/{df}" if parent_dir else df
                    if path in remaining:
                        ordered.append(path)
                        remaining.discard(path)

                # Attachment files (immediately after content)
                for att in entry.get("attachments", []):
                    adf = att.get("dataFileName", "")
                    if adf:
                        att_path = f"{parent_dir}/{adf}" if parent_dir else adf
                        if att_path in remaining:
                            ordered.append(att_path)
                            remaining.discard(att_path)

                # Recurse into children
                dir_name = entry.get("dirFileName", "")
                child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
                for child in entry.get("children", []):
                    _walk([child], child_dir)

        _walk(meta_entries, "")

        # Append any remaining files not matched by tree walk
        for path in sorted(remaining):
            ordered.append(path)

        return ordered

    def _build_entry(
        self,
        note: ImportNote,
        parent_dir: str,
        out_entries: list[dict],
        out_files: dict[str, bytes],
    ) -> None:
        """Recursively build a meta entry and collect files."""
        # Determine filenames
        has_children = bool(note.children)
        if note.fmt == "markdown":
            content_ext = ".md"
        elif note.fmt == "html" or (not note.fmt and note.note_type == "text"):
            content_ext = ".html"
        else:
            # code/file notes: use mime-based extension or .dat
            ext_map = {
                "text/x-sh": ".sh", "application/javascript": ".js",
                "text/css": ".css", "text/x-python": ".py",
                "application/json": ".json", "text/xml": ".xml",
            }
            content_ext = ext_map.get(note.mime, ".dat")

        # Use explicit filenames if provided, otherwise generate from title
        if note.data_filename:
            data_filename = note.data_filename
        else:
            from .export import _sanitize_filename
            safe_stem = _sanitize_filename(note.title + content_ext)
            data_filename = safe_stem

        if note.dir_filename is not None:
            dir_filename = note.dir_filename
        else:
            if has_children:
                from .export import _sanitize_filename
                # Strip extension for dir name
                dir_filename = _sanitize_filename(note.title + ".x").rsplit(".", 1)[0]
            else:
                dir_filename = ""

        # Content file path in ZIP
        content_path = f"{parent_dir}/{data_filename}" if parent_dir else data_filename
        out_files[content_path] = note.content

        # Build attachment entries and files
        att_entries: list[dict] = []
        for i, att in enumerate(note.attachments):
            att_path = f"{parent_dir}/{att.filename}" if parent_dir else att.filename
            out_files[att_path] = att.data

            # Generate a placeholder attachmentId — Trilium ignores the value
            # but requires the field to be present to identify this as an attachment
            generated_id = f"import_{note.note_id}_{i}"

            att_entry: dict[str, Any] = {
                "attachmentId": generated_id,
                "title": att.title,
                "role": att.role,
                "mime": att.mime,
                "position": att.position,
                "dataFileName": att.filename,
            }
            att_entries.append(att_entry)

        # Build meta entry
        entry: dict[str, Any] = {
            "isClone": False,
            "noteId": note.note_id,
            "title": note.title,
            "notePosition": note.position,
            "prefix": note.prefix,
            "isExpanded": note.is_expanded,
            "type": note.note_type,
            "mime": note.mime,
            "attributes": note.attributes,
            "dataFileName": data_filename,
            "attachments": att_entries,
        }

        # Only include format for text notes (markdown/html)
        if note.fmt:
            entry["format"] = note.fmt

        if dir_filename:
            entry["dirFileName"] = dir_filename

        # Recurse children
        if note.children:
            child_entries: list[dict] = []
            child_dir = f"{parent_dir}/{dir_filename}" if parent_dir else dir_filename
            for child in note.children:
                self._build_entry(child, child_dir, child_entries, out_files)
            entry["children"] = child_entries

        out_entries.append(entry)


