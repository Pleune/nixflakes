"""Export: Trilium → filesystem.

Extracts Trilium ZIP exports, manages the meta tree structure
(find/insert/remove/move entries), and handles container placeholders.

Attachment filenames are committed exactly as Trilium exports them.
"""
from __future__ import annotations

import json
import re
import shutil
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .common import META_FILE_NAME, ensure_dir, format_note_line, log, log_note_line
from .meta_tree import (
    find_entry_by_sync_id,
    find_note_path_in_meta,
    find_parent_sync_id_in_meta,
    insert_entry_into_meta,
    remove_entry_from_meta,
    splice_meta_entry,
)


# ---------------------------------------------------------------------------
# Attachment reference discovery
# ---------------------------------------------------------------------------

def _content_file_rel_path(
    parent_dir: str, dir_name: str, data_file: str,
) -> str:
    """Compute the export-relative path of a note's content file.

    After ``_restructure_notes_as_dirs``, content always lives inside the
    note's own directory when ``dirFileName`` is set (for both text notes
    with ``README.md`` and file/image notes with their original filename).
    When the note has no ``dirFileName``, the content file sits directly
    in ``parent_dir``.
    """
    if dir_name:
        entry_dir = (
            f"{parent_dir}/{dir_name}" if parent_dir and dir_name
            else (dir_name or parent_dir)
        )
        return f"{entry_dir}/{data_file}" if entry_dir else data_file
    return f"{parent_dir}/{data_file}" if parent_dir else data_file


# Characters that are part of a filename / URL-path token. We use this to
# enforce strict boundaries when searching for attachment aliases inside
# content files — a hit only counts if it is not bordered by another such
# character on either side, so e.g. ``Foo.png`` will not match inside
# ``1_Foo.png`` or ``Foo.png.bak``. ``/`` is intentionally NOT a boundary
# character, so an alias like ``api/attachments/HASH/Foo.png`` matches
# cleanly without bleeding into a longer URL.
_FILENAME_BOUNDARY_RE = re.compile(r"[A-Za-z0-9_\-.]")


@dataclass
class AttachmentRef:
    """A single literal occurrence of one of an attachment's known aliases."""

    file: Path
    """Path to the content file (relative to export_dir)."""

    line: int
    """1-based line number."""

    col: int
    """0-based character offset within the line."""

    offset: int
    """0-based character offset from start of file."""

    raw: str
    """The literal alias text matched in content (length used for replacement)."""

    data_filename: str = ""
    """The owning attachment's meta ``dataFileName`` (canonical disk filename)."""

    attachment_id: str = ""
    """The owning attachment's meta ``attachmentId`` (may be empty)."""


def _attachment_aliases(
    data_filename: str,
    attachment_id: str,
    note_id: str,
) -> list[str]:
    """Generate every reference form Trilium might emit for one attachment.

    Forms covered (each in literal and URL-percent-encoded variants where
    encoding changes the string):

    - bare ``dataFileName``
    - ``api/attachments/<attachmentId>/<dataFileName>``
    - ``api/attachments/<attachmentId>/image/<dataFileName>``
    - ``api/attachments/<attachmentId>`` (bare download URL)
    - ``api/images/<noteId>/<dataFileName>`` (legacy inline-image form)
    """
    if not data_filename:
        return []

    from urllib.parse import quote

    encoded = quote(data_filename, safe="")
    name_variants = [data_filename]
    if encoded != data_filename:
        name_variants.append(encoded)

    aliases: list[str] = []
    for nv in name_variants:
        aliases.append(nv)
    if attachment_id:
        for nv in name_variants:
            aliases.append(f"api/attachments/{attachment_id}/{nv}")
            aliases.append(f"api/attachments/{attachment_id}/image/{nv}")
        aliases.append(f"api/attachments/{attachment_id}")
    if note_id:
        for nv in name_variants:
            aliases.append(f"api/images/{note_id}/{nv}")

    # Dedupe preserving order; longest-first sorting happens later.
    seen: set[str] = set()
    out: list[str] = []
    for a in aliases:
        if a and a not in seen:
            seen.add(a)
            out.append(a)
    return out


def discover_attachment_refs(export_dir: Path) -> list[AttachmentRef]:
    """Find every literal occurrence of every meta-declared attachment alias.

    Trilium's ``!!!meta.json`` enumerates every attachment per note, including
    its ``attachmentId`` and on-disk ``dataFileName``. From that we can
    enumerate every reference form Trilium could plausibly emit (plain
    filename, ``api/attachments/<id>/<name>``, ``api/images/<noteId>/<name>``,
    URL-encoded variants …) and literal-search each note's own content file
    for them.

    A hit only counts when neither neighboring character is a filename token
    char (alnum / ``_`` / ``-`` / ``.``). Overlapping hits (e.g.
    ``Foo.png`` matching inside ``api/attachments/HASH/Foo.png``) are
    resolved by keeping the longest non-overlapping run — so the API URL
    wins and gets fully rewritten to the final filename, including its
    ``api/...`` prefix.

    Refs are returned sorted by (file, offset).
    """
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return []
    try:
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError):
        return []

    refs: list[AttachmentRef] = []
    _CONTENT_SUFFIXES = (".md", ".html", ".htm")

    def _walk(entries: list[dict], parent_dir: str) -> None:
        for entry in entries:
            note_id = entry.get("noteId", "") or ""
            dir_name = entry.get("dirFileName", "")
            data_file = entry.get("dataFileName", "")
            entry_dir = (
                f"{parent_dir}/{dir_name}" if parent_dir and dir_name
                else (dir_name or parent_dir)
            )
            if data_file:
                cf_rel = _content_file_rel_path(parent_dir, dir_name, data_file)
                content_path = export_dir / cf_rel
                atts = entry.get("attachments", []) or []
                if (
                    atts
                    and content_path.is_file()
                    and content_path.suffix.lower() in _CONTENT_SUFFIXES
                ):
                    try:
                        content = content_path.read_text(errors="replace")
                    except OSError:
                        content = None
                    if content is not None:
                        # Collect all candidate hits across all aliases for this
                        # note's attachments, then resolve overlaps so the
                        # longest alias wins.
                        candidates: list[tuple[int, str, str, str]] = []
                        # (offset, matched_alias, data_filename, attachment_id)
                        for att in atts:
                            adf = att.get("dataFileName", "")
                            if not adf:
                                continue
                            aid = att.get("attachmentId", "") or ""
                            for alias in _attachment_aliases(adf, aid, note_id):
                                for off in _find_alias_offsets(content, alias):
                                    candidates.append((off, alias, adf, aid))
                        kept = _resolve_alias_overlaps(candidates)
                        # Convert kept hits to AttachmentRefs with line/col
                        kept.sort(key=lambda t: t[0])
                        line_num = 1
                        line_start = 0
                        for off, alias, adf, aid in kept:
                            while line_start < off:
                                next_nl = content.find("\n", line_start, off)
                                if next_nl < 0:
                                    break
                                line_num += 1
                                line_start = next_nl + 1
                            refs.append(
                                AttachmentRef(
                                    file=Path(cf_rel),
                                    line=line_num,
                                    col=off - line_start,
                                    offset=off,
                                    raw=alias,
                                    data_filename=adf,
                                    attachment_id=aid,
                                )
                            )
            if entry.get("children"):
                _walk(entry["children"], entry_dir)

    _walk(meta.get("files", []), "")
    refs.sort(key=lambda r: (str(r.file), r.offset))
    return refs


def _find_alias_offsets(content: str, needle: str) -> list[int]:
    """Return every strict-boundary literal occurrence offset of ``needle``.

    Strict boundary: the char immediately before and after the match (if any)
    must not be a filename character (alnum, ``_``, ``-``, ``.``).
    """
    if not needle:
        return []
    out: list[int] = []
    n = len(needle)
    pos = 0
    while True:
        idx = content.find(needle, pos)
        if idx < 0:
            break
        end = idx + n
        before_ok = (idx == 0) or not _FILENAME_BOUNDARY_RE.match(content[idx - 1])
        after_ok = (end == len(content)) or not _FILENAME_BOUNDARY_RE.match(content[end])
        if before_ok and after_ok:
            out.append(idx)
        pos = idx + 1
    return out


def _resolve_alias_overlaps(
    candidates: list[tuple[int, str, str, str]],
) -> list[tuple[int, str, str, str]]:
    """Keep non-overlapping hits, preferring the longest alias on conflict.

    Each candidate is ``(offset, alias, data_filename, attachment_id)``. Two
    candidates conflict iff their ``[offset, offset+len(alias))`` ranges
    intersect. We greedily accept candidates ordered by alias length
    descending, marking consumed ranges; this guarantees that an API-URL
    alias like ``api/attachments/HASH/Foo.png`` wins over the bare
    ``Foo.png`` substring inside it.
    """
    kept: list[tuple[int, str, str, str]] = []
    intervals: list[tuple[int, int]] = []  # (start, end), unsorted
    for cand in sorted(candidates, key=lambda t: -len(t[1])):
        off, alias, _adf, _aid = cand
        start = off
        end = off + len(alias)
        overlaps = False
        for s, e in intervals:
            if not (end <= s or start >= e):
                overlaps = True
                break
        if not overlaps:
            intervals.append((start, end))
            kept.append(cand)
    return kept


# ---------------------------------------------------------------------------
# Attachment rename map
# ---------------------------------------------------------------------------

# Matches Trilium's numeric dedup prefix: "3_Foo_image.png" → prefix=3, rest="Foo_image.png"
_DEDUP_PREFIX_RE = re.compile(r"^(\d+)_(.+)$")


@dataclass
class AttachmentRename:
    """Per-attachment rename entry within a note's plan."""

    data_filename: str
    """Canonical on-disk filename (== meta ``dataFileName``)."""

    new_filename: str
    """Final filename after dedup-prefix strip + sanitize + collision suffix."""

    attachment_id: str = ""
    """Meta ``attachmentId`` (may be empty)."""

    locations: list[tuple[int, int, int, str]] = field(default_factory=list)
    """Per-occurrence ``(line, col, offset, matched_alias)`` tuples in the
    note's content file. ``line`` is 1-based, ``col``/``offset`` 0-based.
    Empty list means this attachment is an orphan (no content reference)."""


def build_rename_map(
    refs: list[AttachmentRef],
    export_dir: Path | None = None,
) -> dict[str, dict[str, AttachmentRename]]:
    """Build a per-note rename plan covering every meta-declared attachment.

    The plan is anchored on ``!!!meta.json`` rather than on the discovered
    refs: every attachment Trilium declares for a note appears in its plan,
    and orphans (no content reference) appear with an empty ``locations``
    list. Downstream stages distinguish:

    - non-orphan entries (``locations`` non-empty) — file renamed on disk,
      content rewritten, meta ``dataFileName`` updated.
    - orphan entries (``locations`` empty) — file deleted, meta entry
      dropped (handled by :func:`_remove_orphan_attachments`).

    Collision suffixing operates on the full per-note attachment pool so
    suffix assignments stay stable regardless of whether a particular
    attachment is currently referenced. Within a colliding base group,
    referenced attachments sort first (by first content offset), then
    unreferenced ones in meta declaration order.

    Returns: ``{content_file_rel_path: {data_filename: AttachmentRename}}``.
    """
    from collections import defaultdict

    if export_dir is None:
        # Backwards-compat: try to recover meta path from refs (rare).
        return {}

    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return {}
    try:
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError):
        return {}

    # Index refs by (content_file, data_filename) -> list[(line, col, offset, raw)]
    refs_by_key: dict[tuple[str, str], list[tuple[int, int, int, str]]] = defaultdict(list)
    for r in refs:
        refs_by_key[(str(r.file), r.data_filename)].append(
            (r.line, r.col, r.offset, r.raw)
        )

    result: dict[str, dict[str, AttachmentRename]] = {}

    def _walk(entries: list[dict], parent_dir: str) -> None:
        for entry in entries:
            dir_name = entry.get("dirFileName", "")
            data_file = entry.get("dataFileName", "")
            entry_dir = (
                f"{parent_dir}/{dir_name}" if parent_dir and dir_name
                else (dir_name or parent_dir)
            )
            atts = entry.get("attachments", []) or []
            if data_file and atts:
                cf_rel = _content_file_rel_path(parent_dir, dir_name, data_file)

                # Compute base filename (sanitize, prefix-strip) per attachment
                bases: list[str] = []
                for att in atts:
                    adf = att.get("dataFileName", "") or ""
                    m = _DEDUP_PREFIX_RE.match(adf) if adf else None
                    base = _sanitize_filename(m.group(2) if m else adf) if adf else ""
                    bases.append(base)

                # Group attachment indices by base for collision detection
                base_groups: dict[str, list[int]] = defaultdict(list)
                for i, base in enumerate(bases):
                    if base:
                        base_groups[base].append(i)

                file_map: dict[str, AttachmentRename] = {}
                for base, idxs in base_groups.items():
                    # Sort: referenced first (by first occurrence offset), then
                    # unreferenced in meta order.
                    def _sort_key(i: int) -> tuple:
                        adf_i = atts[i].get("dataFileName", "") or ""
                        locs = refs_by_key.get((cf_rel, adf_i), [])
                        if locs:
                            return (0, locs[0][2], i)  # offset of first ref
                        return (1, 0, i)

                    sorted_idxs = sorted(idxs, key=_sort_key)
                    if len(sorted_idxs) == 1:
                        i = sorted_idxs[0]
                        adf_i = atts[i].get("dataFileName", "") or ""
                        aid_i = atts[i].get("attachmentId", "") or ""
                        locs = refs_by_key.get((cf_rel, adf_i), [])
                        file_map[adf_i] = AttachmentRename(
                            data_filename=adf_i,
                            attachment_id=aid_i,
                            new_filename=base,
                            locations=locs,
                        )
                    else:
                        dot = base.rfind(".")
                        stem, ext = (base[:dot], base[dot:]) if dot > 0 else (base, "")
                        for n, i in enumerate(sorted_idxs, 1):
                            adf_i = atts[i].get("dataFileName", "") or ""
                            aid_i = atts[i].get("attachmentId", "") or ""
                            locs = refs_by_key.get((cf_rel, adf_i), [])
                            file_map[adf_i] = AttachmentRename(
                                data_filename=adf_i,
                                attachment_id=aid_i,
                                new_filename=f"{stem}_{n}{ext}",
                                locations=locs,
                            )

                if file_map:
                    result[cf_rel] = file_map

            if entry.get("children"):
                _walk(entry["children"], entry_dir)

    _walk(meta.get("files", []), "")
    return result


# ---------------------------------------------------------------------------
# Apply renames
# ---------------------------------------------------------------------------

def _sanitize_filename(name: str) -> str:
    """Normalize a filename for clean git paths and safe ZIP entries.

    - Lowercase
    - Slashes to _
    - Spaces to _
    - Remove weird characters (keep alphanumeric, _, .)
    - Collapse multiple _ into one
    - Truncate stem to 60 chars max
    """
    # Separate stem and extension to preserve the dot
    dot = name.rfind(".")
    if dot > 0:
        stem, ext = name[:dot], name[dot:]
    else:
        stem, ext = name, ""

    stem = stem.lower()
    # Replace slashes and spaces with underscore
    stem = stem.replace("/", "_").replace("\\", "_").replace(" ", "_")
    # Keep only alphanumeric, underscore, and dot
    stem = re.sub(r"[^a-z0-9_.]", "", stem)
    # Collapse multiple underscores
    stem = re.sub(r"_+", "_", stem)
    # Strip leading/trailing underscores
    stem = stem.strip("_")
    # Truncate long stems
    if len(stem) > 60:
        stem = stem[:60].rstrip("_")

    ext = ext.lower()

    return f"{stem}{ext}" if stem else f"attachment{ext}"


_ATTACHMENTS_SUBDIR = ""  # Attachments live directly next to README.md (no subdirectory)


def apply_rename_map(
    export_dir: Path,
    rename_map: dict[str, dict[str, AttachmentRename]],
) -> None:
    """Apply the rename map: rewrite content references and move files.

    For each content file in the rename map:
    1. Replace all raw references in the content with the new sanitized filename
    2. Rename the exported file on disk to the new name (same directory)
    3. Delete unreferenced attachment files (on disk but not in any src/href)

    Files that don't exist on disk (e.g. orphan API refs) are skipped for the move step.
    """
    for file_path_str, file_map in rename_map.items():
        content_path = export_dir / file_path_str
        if not content_path.exists():
            continue

        # Determine the directory where attachments currently live (same as content file)
        note_dir = content_path.parent

        # --- Step 1: Replace strings in content (only entries with locations) ---
        content = content_path.read_text(errors="replace")

        # Build replacements sorted by offset descending so we can splice without shifting
        replacements: list[tuple[int, int, str]] = []  # (offset, length, new_text)
        for entry in file_map.values():
            new_ref = entry.new_filename
            for _line, _col, offset, matched in entry.locations:
                replacements.append((offset, len(matched), new_ref))

        # Apply in reverse offset order
        replacements.sort(key=lambda r: r[0], reverse=True)
        if replacements:
            content_chars = list(content)
            for offset, length, new_text in replacements:
                content_chars[offset:offset + length] = list(new_text)
            new_content = "".join(content_chars)
            if new_content != content:
                content_path.write_text(new_content)

        # --- Step 2: Rename non-orphan files in place ---
        # Orphan entries (no locations) are handled separately by
        # _remove_orphan_attachments — we deliberately do NOT rename their
        # files here, since they're going to be deleted entirely.
        for entry in file_map.values():
            if not entry.locations:
                continue
            src = note_dir / entry.data_filename
            dst = note_dir / entry.new_filename
            if src == dst:
                continue
            if src.exists() and not dst.exists():
                src.rename(dst)


def delete_unreferenced_attachments(
    export_dir: Path,
    rename_map: dict[str, dict[str, AttachmentRename]],
) -> list[str]:
    """Delete attachment files on disk that are not referenced in any content.

    After apply_rename_map, referenced files are renamed in place (same dir as content).
    Only deletes files that are:
    - Not a renamed/referenced attachment
    - Not declared as dataFileName for any note in the meta
    - Not a content/meta file (.md, .html, .json)

    Returns list of deleted file paths (relative to export_dir).
    """
    # Collect all dataFileNames from meta (these are legitimate note content files)
    meta_path = export_dir / META_FILE_NAME
    meta_data_files: set[str] = set()
    if meta_path.exists():
        meta = json.loads(meta_path.read_text())

        def _collect_data_files(entries: list, parent_dir: str) -> None:
            for entry in entries:
                dir_name = entry.get("dirFileName", "")
                entry_dir = (
                    f"{parent_dir}/{dir_name}"
                    if parent_dir and dir_name
                    else (dir_name or parent_dir)
                )
                df = entry.get("dataFileName", "")
                if df:
                    # Files live inside their own dir (README.md or binary)
                    if dir_name:
                        full = f"{entry_dir}/{df}" if entry_dir else df
                    else:
                        full = f"{parent_dir}/{df}" if parent_dir else df
                    meta_data_files.add(full)
                # Also protect attachment files declared in meta
                for att in entry.get("attachments", []):
                    adf = att.get("dataFileName", "")
                    if adf:
                        # Attachments live in the note's own dir
                        att_full = f"{entry_dir}/{adf}" if entry_dir else adf
                        meta_data_files.add(att_full)
                if entry.get("children"):
                    _collect_data_files(entry["children"], entry_dir)

        _collect_data_files(meta.get("files", []), "")

    # Collect all renamed attachment files (they're referenced)
    protected: set[Path] = set()
    for file_path_str, file_map in rename_map.items():
        content_path = export_dir / file_path_str
        protected.add(content_path)
        note_dir = content_path.parent
        for entry in file_map.values():
            if entry.locations:
                protected.add(note_dir / entry.new_filename)

    skip_names = {META_FILE_NAME}
    content_exts = {".md", ".html", ".htm", ".json"}

    deleted: list[str] = []
    for path in sorted(export_dir.rglob("*")):
        if not path.is_file():
            continue
        if path in protected:
            continue
        if path.name in skip_names:
            continue
        # Keep content and meta files
        if path.suffix in content_exts:
            continue
        # Keep files declared as dataFileName in meta (note content like PDFs)
        rel = str(path.relative_to(export_dir))
        if rel in meta_data_files:
            continue

        # This is a loose binary file not referenced in any content
        # and not declared as a note's dataFileName — delete it
        path.unlink()
        deleted.append(rel)

    if deleted:
        log(f"[export] deleted {len(deleted)} unreferenced attachment file(s):")
        for rel in deleted:
            log(f"    {rel}")

    return deleted


def _stabilize_meta(export_dir: Path) -> None:
    """Stabilize meta fields to ensure export determinism across import/export cycles.

    - Replaces attachmentId with a deterministic value derived from (noteId, dataFileName)
    - Sorts attachments by dataFileName for stable ordering
    - Sorts attributes by (type, name, value) for stable ordering
    """
    import hashlib

    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return

    meta = json.loads(meta_path.read_text())

    def _stable_id(title: str, data_filename: str) -> str:
        """Generate a deterministic 12-char ID from note title + attachment filename."""
        h = hashlib.sha256(f"{title}:{data_filename}".encode()).digest()
        import base64
        return base64.b64encode(h[:9], altchars=b"AB").decode()[:12]

    def _walk(entries: list, parent_dir: str = "") -> None:
        for entry in entries:
            title = entry.get("title", "")
            dir_name = entry.get("dirFileName", "")
            entry_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)

            # Remove viewConfig attachments (e.g. pdfHistory.json) — too noisy in git
            if entry.get("attachments"):
                for att in entry["attachments"]:
                    if att.get("role") == "viewConfig":
                        # Delete the file on disk
                        adf = att.get("dataFileName", "")
                        if adf:
                            att_path = (export_dir / entry_dir / adf) if entry_dir else (export_dir / adf)
                            if att_path.exists():
                                att_path.unlink()
                entry["attachments"] = [
                    a for a in entry["attachments"] if a.get("role") != "viewConfig"
                ]

            # Stabilize attachmentId
            for att in entry.get("attachments", []):
                df = att.get("dataFileName", "")
                if df and title:
                    att["attachmentId"] = _stable_id(title, df)

            # Sort attachments by dataFileName
            if entry.get("attachments"):
                entry["attachments"].sort(
                    key=lambda a: a.get("dataFileName", "")
                )

            # Sort attributes by (type, name, value) for stable order
            if entry.get("attributes"):
                entry["attributes"].sort(
                    key=lambda a: (a.get("type", ""), a.get("name", ""), a.get("value", ""))
                )

            if entry.get("children"):
                _walk(entry["children"], entry_dir)

    _walk(meta.get("files", []))
    meta_path.write_text(json.dumps(meta, indent=2))


def pretty_format_export_json_files(export_dir: Path) -> None:
    if not export_dir.exists():
        return
    for path in sorted(export_dir.rglob("*.json")):
        if not path.is_file():
            continue
        try:
            payload = json.loads(path.read_text())
            formatted = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
            if path.read_text() != formatted:
                path.write_text(formatted)
                log(f"pretty-formatted exported JSON {path.relative_to(export_dir)}")
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            log(f"skipping JSON pretty-format for {path.relative_to(export_dir)}: {exc}")


def extract_export(zip_bytes: bytes, export_dir: Path, pretty: bool = True,
                   root_note_id: str = "root") -> None:
    if export_dir.exists():
        shutil.rmtree(export_dir)
    ensure_dir(export_dir)
    with tempfile.TemporaryDirectory(prefix="trilium-git-sync-") as tmp:
        archive = Path(tmp) / "export.zip"
        archive.write_bytes(zip_bytes)
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(export_dir)
    _flatten_root_dir(export_dir, root_note_id)
    _ensure_container_placeholders(export_dir)
    _replace_spaces_in_paths(export_dir)
    _restructure_notes_as_dirs(export_dir)
    _normalize_attachments(export_dir)
    _stabilize_meta(export_dir)
    _generate_toc(export_dir)
    if pretty:
        pretty_format_export_json_files(export_dir)

_TOC_START = "<!-- TOC START -->"
_TOC_END = "<!-- TOC END -->"


def _encode_link_path(path: str) -> str:
    """URL-encode spaces and special chars in a markdown link path."""
    from urllib.parse import quote
    # Encode each path segment, preserve slashes
    return "/".join(quote(seg, safe="") for seg in path.split("/"))


def _generate_toc(export_dir: Path, readme_path: Path | None = None) -> None:
    """Generate a table of contents in the repo README.md.

    Writes a fenced section between TOC START/END markers.
    - If markers exist: replace in place.
    - If no markers but a top-level `# Header` exists: insert after it.
    - Otherwise: insert at the top of the file.
    Creates README.md if it doesn't exist.
    """
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return

    meta = json.loads(meta_path.read_text())
    if readme_path is None:
        readme_path = export_dir.parent / "README.md"

    toc_lines = _build_toc_lines(meta.get("files", []), export_dir, depth=0)
    toc_block = f"{_TOC_START}\n" + "\n".join(toc_lines) + f"\n{_TOC_END}"

    if readme_path.exists():
        content = readme_path.read_text()
        if _TOC_START in content and _TOC_END in content:
            # Replace existing TOC section in place
            before = content[: content.index(_TOC_START)]
            after = content[content.index(_TOC_END) + len(_TOC_END) :]
            content = before + toc_block + after
        else:
            # Insert after top-level header if one exists
            lines = content.split("\n")
            h1_idx = None
            for i, line in enumerate(lines):
                if line.startswith("# "):
                    h1_idx = i
                    break
            if h1_idx is not None:
                # Insert after the header (and a blank line)
                before = "\n".join(lines[: h1_idx + 1])
                after = "\n".join(lines[h1_idx + 1 :])
                content = before + "\n\n" + toc_block + "\n" + after
            else:
                # No header — insert at top
                content = toc_block + "\n\n" + content
    else:
        content = f"# Notes\n\n{toc_block}\n"

    readme_path.write_text(content)


def _build_toc_lines(
    entries: list, export_dir: Path, depth: int, parent_dir: str = "",
) -> list[str]:
    """Recursively build TOC lines from meta entries."""
    lines: list[str] = []
    indent = "  " * depth

    for entry in entries:
        note_id = entry.get("noteId", "")

        # Skip root wrapper, recurse into children
        if note_id == "root":
            root_dir = entry.get("dirFileName", "")
            if entry.get("children"):
                lines.extend(
                    _build_toc_lines(entry["children"], export_dir, depth, root_dir)
                )
            continue

        title = entry.get("title", "Untitled")
        is_clone = entry.get("isClone", False)
        note_type = entry.get("type", "text")
        data_file = entry.get("dataFileName", "")
        dir_name = entry.get("dirFileName", "")

        # Build the relative path from export_dir
        if dir_name and data_file:
            rel_path = _content_file_rel_path(parent_dir, dir_name, data_file)
        elif parent_dir:
            rel_path = f"{parent_dir}/{data_file}" if data_file else ""
        else:
            rel_path = data_file

        # For clones, link to the original note's path
        if is_clone and rel_path:
            link_text = f"{title} (clone)"
            encoded = _encode_link_path(f"export/{rel_path}")
            lines.append(f"{indent}- [{link_text}]({encoded})")
        elif rel_path:
            # Determine label suffix for non-text types
            suffix = ""
            if note_type == "file":
                suffix = " 📎"
            elif note_type == "code":
                suffix = " 💻"
            encoded = _encode_link_path(f"export/{rel_path}")
            lines.append(f"{indent}- [{title}{suffix}]({encoded})")
        else:
            lines.append(f"{indent}- {title}")

        # Recurse into children
        child_dir = (
            f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
        )
        if entry.get("children"):
            lines.extend(
                _build_toc_lines(entry["children"], export_dir, depth + 1, child_dir)
            )

    return lines



def _replace_spaces_in_paths(export_dir: Path) -> None:
    """Replace spaces with underscores in content file and directory names.

    Updates meta.json dataFileName/dirFileName to match.
    """
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return

    meta = json.loads(meta_path.read_text())

    def _fix_name(name: str) -> str:
        return name.replace(" ", "_")

    def _walk_entries(entries: list) -> None:
        for entry in entries:
            # Update dataFileName
            df = entry.get("dataFileName", "")
            if df and " " in df:
                entry["dataFileName"] = _fix_name(df)

            # Update dirFileName
            drf = entry.get("dirFileName", "")
            if drf and " " in drf:
                entry["dirFileName"] = _fix_name(drf)

            # Update attachment dataFileNames
            for att in entry.get("attachments", []):
                adf = att.get("dataFileName", "")
                if adf and " " in adf:
                    att["dataFileName"] = _fix_name(adf)

            if entry.get("children"):
                _walk_entries(entry["children"])

    _walk_entries(meta.get("files", []))
    meta_path.write_text(json.dumps(meta, indent=2))

    # Now rename actual files/dirs on disk (bottom-up to avoid path invalidation)
    # Collect all paths that need renaming, deepest first
    renames: list[tuple[Path, Path]] = []
    for path in sorted(export_dir.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if " " in path.name:
            new_path = path.parent / path.name.replace(" ", "_")
            renames.append((path, new_path))

    for old, new in renames:
        if old.exists() and not new.exists():
            old.rename(new)

    # Rewrite references in content files: replace spaces with underscores in
    # src="..." and href="..." attributes (attachment filenames)
    for content_file in export_dir.rglob("*"):
        if not content_file.is_file():
            continue
        if content_file.suffix not in (".md", ".html", ".htm"):
            continue
        try:
            text = content_file.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if " " not in text:
            continue
        # Replace spaces in src="..." and href="..." attribute values
        new_text = re.sub(
            r'((?:src|href)=")([^"]+)(")',
            lambda m: m.group(1) + m.group(2).replace(" ", "_") + m.group(3),
            text,
        )
        if new_text != text:
            content_file.write_text(new_text, encoding="utf-8")


def _restructure_notes_as_dirs(export_dir: Path) -> None:
    """Move every note's content file into its own directory as README.md.

    Transforms: parent/<Note>.md + parent/<Note>/  →  parent/<Note>/README.md
    For leaf notes (no dir yet): parent/<Leaf>.md  →  parent/<Leaf>/README.md

    Updates meta dataFileName to 'README.md' and ensures dirFileName exists.
    """
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return

    meta = json.loads(meta_path.read_text())

    def _walk(entries: list, parent_dir: str) -> None:
        for entry in entries:
            note_id = entry.get("noteId", "")
            if note_id == "root":
                root_dir = entry.get("dirFileName", "")
                if entry.get("children"):
                    _walk(entry["children"], root_dir)
                continue

            data_file = entry.get("dataFileName", "")
            dir_name = entry.get("dirFileName", "")

            # Skip if already README.md or no data file
            if not data_file or data_file == "README.md":
                if entry.get("children"):
                    child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
                    _walk(entry["children"], child_dir)
                continue

            # Binary note types (image, file) keep their original filename
            # but still get moved into their own dir if they don't have one
            note_type = entry.get("type", "text")
            if note_type in ("image", "file"):
                if not dir_name:
                    stem = data_file.rsplit(".", 1)[0] if "." in data_file else data_file
                    dir_name = stem
                    entry["dirFileName"] = dir_name

                # Move into dir but keep original filename
                src = (export_dir / parent_dir / data_file) if parent_dir else (export_dir / data_file)
                dest_dir = (export_dir / parent_dir / dir_name) if parent_dir else (export_dir / dir_name)
                dest = dest_dir / data_file

                if src.exists() and not dest.exists():
                    ensure_dir(dest_dir)
                    src.rename(dest)

                # Move adjacent attachment files into the note's dir
                src_dir = (export_dir / parent_dir) if parent_dir else export_dir
                for att in entry.get("attachments", []):
                    att_file = att.get("dataFileName", "")
                    if not att_file:
                        continue
                    att_src = src_dir / att_file
                    if att_src.exists():
                        att_dest = dest_dir / att_file
                        if not att_dest.exists():
                            att_src.rename(att_dest)

                # Recurse into children
                child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
                if entry.get("children"):
                    _walk(entry["children"], child_dir)
                continue

            # Determine the directory name for this note
            if not dir_name:
                # Leaf note — derive dir name from data file (strip extension)
                stem = data_file.rsplit(".", 1)[0] if "." in data_file else data_file
                # Strip .clone suffix if present
                if stem.endswith(".clone"):
                    stem = stem[:-6]
                dir_name = stem
                entry["dirFileName"] = dir_name

            # Move the file: parent_dir/<data_file> → parent_dir/<dir_name>/README.md
            src = (export_dir / parent_dir / data_file) if parent_dir else (export_dir / data_file)
            dest_dir = (export_dir / parent_dir / dir_name) if parent_dir else (export_dir / dir_name)
            dest = dest_dir / "README.md"

            if src.exists() and not dest.exists():
                ensure_dir(dest_dir)
                src.rename(dest)

            # Move adjacent attachment files into the note's dir
            # These are raw Trilium exports (e.g. "1_Radar_eval_image.jpeg")
            # that live next to the content file before normalization
            src_dir = (export_dir / parent_dir) if parent_dir else export_dir
            for att in entry.get("attachments", []):
                att_file = att.get("dataFileName", "")
                if not att_file:
                    continue
                att_src = src_dir / att_file
                if att_src.exists():
                    att_dest = dest_dir / att_file
                    if not att_dest.exists():
                        att_src.rename(att_dest)

            entry["dataFileName"] = "README.md"

            # Recurse into children
            child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
            if entry.get("children"):
                _walk(entry["children"], child_dir)

    _walk(meta.get("files", []), "")
    meta_path.write_text(json.dumps(meta, indent=2))


def _flatten_root_dir(export_dir: Path, root_note_id: str = "root") -> None:
    """Move contents of the root wrapper dir up into export_dir.

    Trilium exports as: export_dir/root/<files...>
    We flatten to:      export_dir/<files...>

    Also updates the meta's root entry dirFileName to empty string.
    """
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        # Check if meta is inside a subdirectory
        subdirs = [d for d in export_dir.iterdir() if d.is_dir()]
        if len(subdirs) == 1 and (subdirs[0] / META_FILE_NAME).exists():
            meta_path = subdirs[0] / META_FILE_NAME
        else:
            return

    # Find the root wrapper directory
    meta = json.loads(meta_path.read_text())
    root_entry = None
    for entry in meta.get("files", []):
        if entry.get("noteId") == root_note_id:
            root_entry = entry
            break

    if not root_entry:
        return

    root_dir_name = root_entry.get("dirFileName", "root")
    root_dir = export_dir / root_dir_name

    if not root_dir.is_dir():
        return

    # Move meta first (it's at root_dir level or export_dir level)
    if meta_path.parent == root_dir:
        # Meta is inside root dir — move everything up
        pass
    elif meta_path.parent == export_dir:
        # Meta is already at export_dir level — just move root dir contents up
        pass

    # Move all contents of root_dir up to export_dir
    for item in list(root_dir.iterdir()):
        dest = export_dir / item.name
        if dest.exists():
            if dest.is_dir():
                shutil.rmtree(dest)
            else:
                dest.unlink()
        item.rename(dest)

    # Remove now-empty root dir
    root_dir.rmdir()

    # Promote the root note's own data file to README.md so the user lands
    # on the root note's content when browsing ``export/`` in git. Trilium
    # exports root content as ``root.md`` (or whatever ``dataFileName`` says)
    # next to the children wrapper, which previously meant the file was kept
    # at ``export/root.md`` and ignored by every downstream consumer.
    root_data_file = root_entry.get("dataFileName", "")
    if root_data_file and root_data_file != "README.md":
        src = export_dir / root_data_file
        dst = export_dir / "README.md"
        if src.exists():
            if dst.exists():
                if dst.is_dir():
                    shutil.rmtree(dst)
                else:
                    dst.unlink()
            src.rename(dst)
            root_entry["dataFileName"] = "README.md"
    elif not root_data_file:
        # Root has no content file (empty note).  Create a placeholder so
        # ``export/README.md`` always exists in git — it doubles as the
        # landing page when browsing the export directory.
        dst = export_dir / "README.md"
        if not dst.exists():
            dst.write_text("")
        root_entry["dataFileName"] = "README.md"

    # Update meta: set root dirFileName to empty so consumers don't prepend it
    root_entry["dirFileName"] = ""
    # Normalize the configured root's wrapper to the synthetic ``"root"`` id.
    # The whole in-repo representation (rewrite_ids, meta_tree, manifest,
    # move/clone logic) uses ``"root"`` as the sentinel for the top-level
    # wrapper and synthetic parent. For the default global root this is a
    # no-op; for a custom ``--root-note-id`` it remaps the exported wrapper
    # (whose noteId is the custom note's id) onto that same sentinel so
    # downstream code keeps working unchanged.
    root_entry["noteId"] = "root"
    # Meta may have been moved — write to export_dir
    final_meta = export_dir / META_FILE_NAME
    final_meta.write_text(json.dumps(meta, indent=2))


def _normalize_attachments(export_dir: Path) -> None:
    """Discover, rename, relocate, and prune attachments in an export."""
    refs = discover_attachment_refs(export_dir)
    rename_map = build_rename_map(refs, export_dir)
    apply_rename_map(export_dir, rename_map)
    deleted = delete_unreferenced_attachments(export_dir, rename_map)
    _update_meta_attachment_paths(export_dir, rename_map)
    orphan_removed = _remove_orphan_attachments(export_dir, rename_map)
    _log_attachment_normalization(
        export_dir, rename_map=rename_map, orphan_removed=orphan_removed, deleted=deleted,
    )


def _remove_orphan_attachments(
    export_dir: Path,
    rename_map: dict[str, dict[str, "AttachmentRename"]],
) -> dict[str, list[str]]:
    """Remove meta-declared attachments that have no content reference.

    The plan in ``rename_map`` is meta-driven and includes every declared
    attachment, with ``locations == []`` marking orphans. Trilium retains
    attachments server-side, so dropping orphans from git is safe and
    reversible: a future export will reintroduce them if anything starts
    referencing them again.

    For each orphan:
    - Delete the file on disk (if it exists).
    - Remove the attachment entry from its parent note's ``attachments`` list.

    Returns: ``{entry_dir: [removed_filename, ...]}`` for logging.
    """
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return {}
    try:
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError):
        return {}

    # Build orphan set per note dir from the plan: any plan entry with no
    # content locations is an orphan.
    orphans_per_dir: dict[str, set[str]] = {}
    for cfs, fm in rename_map.items():
        d_path = Path(cfs).parent
        d = "" if str(d_path) == "." else str(d_path)
        bucket = orphans_per_dir.setdefault(d, set())
        for entry in fm.values():
            if not entry.locations:
                bucket.add(entry.data_filename)

    removed: dict[str, list[str]] = {}
    changed = False

    def _walk(entries: list[dict], parent_dir: str) -> None:
        nonlocal changed
        for entry in entries:
            dir_name = entry.get("dirFileName", "")
            data_file = entry.get("dataFileName", "")
            entry_dir = (
                f"{parent_dir}/{dir_name}" if parent_dir and dir_name
                else (dir_name or parent_dir)
            )
            att_dir = entry_dir if dir_name else parent_dir
            orphans = orphans_per_dir.get(att_dir, set())

            atts = entry.get("attachments", []) or []
            kept: list[dict] = []
            for att in atts:
                adf = att.get("dataFileName", "")
                if not adf or adf not in orphans:
                    kept.append(att)
                    continue
                # Orphan — remove file + drop from meta
                disk_path = (export_dir / att_dir / adf) if att_dir else (export_dir / adf)
                if disk_path.exists():
                    try:
                        disk_path.unlink()
                    except OSError:
                        # If we can't remove the file, keep the meta entry
                        # too so meta and disk stay consistent.
                        kept.append(att)
                        continue
                removed.setdefault(att_dir, []).append(adf)
                changed = True
            if len(kept) != len(atts):
                entry["attachments"] = kept

            if entry.get("children"):
                _walk(entry["children"], entry_dir)

    _walk(meta.get("files", []), "")

    if changed:
        meta_path.write_text(json.dumps(meta, indent=2))

    return removed


def _log_attachment_normalization(
    export_dir: Path,
    rename_map: dict[str, dict[str, "AttachmentRename"]],
    orphan_removed: dict[str, list[str]],
    deleted: list[str],
) -> None:
    """Log per-note attachment discovery and rename outcomes.

    For each note that had attachment references, prints the note descriptor
    followed by ``exported_name -> final_name`` lines (one per unique
    attachment file). Also lists meta-declared attachments not referenced in
    content (orphans) and notes that have meta-declared attachments but no
    content references at all.
    """
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return
    try:
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError):
        return

    # content-file path (export-relative posix) -> (syncId, title, entry_dir, declared_atts)
    content_index: dict[str, tuple[str | None, str | None, str, list[dict]]] = {}
    # entry_dir -> (syncId, title, declared_atts) for orphan reporting
    dir_index: dict[str, tuple[str | None, str | None, list[dict]]] = {}

    def _walk(entries: list[dict], parent_dir: str) -> None:
        for entry in entries:
            sid = entry.get("noteId")
            title = entry.get("title")
            dir_name = entry.get("dirFileName", "")
            data_file = entry.get("dataFileName", "")
            entry_dir = (
                f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
            )
            atts = entry.get("attachments", []) or []
            if data_file:
                cf = _content_file_rel_path(parent_dir, dir_name, data_file)
                cdir = entry_dir if dir_name else parent_dir
                content_index[cf] = (sid, title, cdir, atts)
                if atts:
                    dir_index.setdefault(cdir, (sid, title, atts))
            if entry.get("children"):
                _walk(entry["children"], entry_dir)

    _walk(meta.get("files", []), "")

    any_logged = False

    # Per-note rename listings (entries with at least one location)
    for content_file_str in sorted(rename_map.keys()):
        file_map = rename_map[content_file_str]
        if not file_map:
            continue
        ordered: list[tuple[str, str]] = []
        seen_data: set[str] = set()
        for entry in sorted(
            file_map.values(),
            key=lambda e: (e.locations[0][2] if e.locations else 10**12),
        ):
            if not entry.locations:
                continue  # orphans listed separately below
            if entry.data_filename in seen_data:
                continue
            seen_data.add(entry.data_filename)
            ordered.append((entry.data_filename, entry.new_filename))

        sid, title, cdir, _declared = content_index.get(
            content_file_str, (None, None, str(Path(content_file_str).parent), [])
        )
        orphans_for_dir = orphan_removed.get(cdir, [])

        if not ordered and not orphans_for_dir:
            continue

        if not any_logged:
            log("[export] attachment normalization:")
            any_logged = True
        log("  " + format_note_line(None, sid, title, suffix=f"({content_file_str})"))
        for data_filename, final in ordered:
            arrow = "=" if data_filename == final else "→"
            log(f"      {data_filename} {arrow} {final}")
        for old_name in orphans_for_dir:
            log(f"      {old_name} → ∅   (orphan removed: declared in meta, not referenced in content)")

    # Notes whose attachments were ALL orphans (no content refs anywhere) —
    # they won't appear in `rename_map`, so list them here. Each removed
    # filename is reported as deleted.
    referenced_dirs = {
        content_index[cf][2] for cf in rename_map.keys() if cf in content_index
    }
    for cdir, old_names in sorted(orphan_removed.items()):
        if cdir in referenced_dirs or not old_names:
            continue
        sid_title = dir_index.get(cdir)
        sid = sid_title[0] if sid_title else None
        title = sid_title[1] if sid_title else None
        if not any_logged:
            log("[export] attachment normalization:")
            any_logged = True
        log("  " + format_note_line(None, sid, title, suffix=f"({cdir or '<root>'})"))
        for old_name in old_names:
            log(f"      {old_name} → ∅   (orphan removed: no content refs)")


def _update_meta_attachment_paths(
    export_dir: Path,
    rename_map: dict[str, dict[str, AttachmentRename]],
) -> None:
    """Rewrite !!!meta.json so attachment dataFileName entries reflect renamed files.

    After apply_rename_map, attachment files are renamed in place (same dir as content).
    Update meta attachment dataFileNames to match the new filenames.
    """
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return

    meta = json.loads(meta_path.read_text())

    # Build lookup: (parent_dir, data_filename) → new_filename
    # Only non-orphan entries (with locations) get their meta updated; orphan
    # entries are about to be removed from meta entirely by
    # _remove_orphan_attachments.
    rename_lookup: dict[tuple[str, str], str] = {}
    for file_path_str, file_map in rename_map.items():
        parent_dir = str(Path(file_path_str).parent)
        if parent_dir == ".":
            parent_dir = ""
        for entry in file_map.values():
            if not entry.locations:
                continue
            rename_lookup[(parent_dir, entry.data_filename)] = entry.new_filename

    changed = False

    def _walk(entries: list[dict], parent_dir: str) -> None:
        nonlocal changed
        for entry in entries:
            dir_name = entry.get("dirFileName", "")
            entry_dir = (
                f"{parent_dir}/{dir_name}"
                if parent_dir and dir_name
                else (dir_name or parent_dir)
            )

            # After restructuring, attachments live in entry_dir when
            # the note has its own directory, otherwise in parent_dir.
            att_lookup_dir = entry_dir if dir_name else parent_dir

            for att in entry.get("attachments", []):
                adf = att.get("dataFileName", "")
                if not adf:
                    continue
                new_name = rename_lookup.get((att_lookup_dir, adf))
                if new_name is not None:
                    att["dataFileName"] = new_name
                    changed = True

            if entry.get("children"):
                _walk(entry["children"], entry_dir)

    _walk(meta.get("files", []), "")

    if changed:
        meta_path.write_text(json.dumps(meta, indent=2))


def _ensure_container_placeholders(export_dir: Path) -> None:
    """Ensure container notes (dirFileName but no dataFileName) get a placeholder .md file.
    Without this, container notes vanish from git since commit_export only tracks files."""
    meta_path = export_dir / META_FILE_NAME
    if not meta_path.exists():
        return
    meta = json.loads(meta_path.read_text())
    changed = _fix_container_entries(meta.get("files", []), export_dir, "")
    if changed:
        meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")


def _fix_container_entries(entries: list, export_dir: Path, parent_dir: str) -> bool:
    """Recursively ensure all notes have a dataFileName (empty notes get a placeholder .md)."""
    changed = False
    for entry in entries:
        dir_name = entry.get("dirFileName", "")
        data_file = entry.get("dataFileName", "")
        note_id = entry.get("noteId", "")

        # Skip root wrapper
        if note_id == "root":
            child_dir = dir_name or parent_dir
            if entry.get("children"):
                if _fix_container_entries(entry["children"], export_dir, child_dir):
                    changed = True
            continue

        # Note with no data file — create a placeholder
        if not data_file:
            title = entry.get("title", note_id or "note")
            placeholder_name = f"{title}.md"
            placeholder_path = (export_dir / parent_dir / placeholder_name) if parent_dir else (export_dir / placeholder_name)
            if not placeholder_path.exists():
                ensure_dir(placeholder_path.parent)
                placeholder_path.write_text("")
            entry["dataFileName"] = placeholder_name
            entry["format"] = "markdown"
            changed = True

        # Recurse
        child_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
        if entry.get("children"):
            if _fix_container_entries(entry["children"], export_dir, child_dir):
                changed = True
    return changed


# Meta tree operations are re-exported from meta_tree module for backwards compatibility
# find_entry_by_sync_id, find_note_path_in_meta, find_parent_sync_id_in_meta,
# insert_entry_into_meta, remove_entry_from_meta, splice_meta_entry
# are imported at the top of this file from .meta_tree


def remove_note_from_export(
    export_dir: Path,
    meta: dict,
    sync_id: str,
    trilium_id: str | None = None,
) -> None:
    """Remove a note from the export: delete its files and remove from meta."""
    from .git_lfs import remove_lfs_tracking

    path_info = find_note_path_in_meta(meta, sync_id)
    entry = find_entry_by_sync_id(meta, sync_id)
    if entry is None or path_info is None:
        return

    parent_dir = path_info[0]
    _delete_entry_files(export_dir, parent_dir, entry, remove_lfs_tracking)
    remove_entry_from_meta(meta, sync_id)
    log("[push] removed from export:")
    log_note_line(trilium_id, sync_id, entry.get("title"))


def _delete_entry_files(export_dir: Path, parent_dir: str, entry: dict, remove_lfs_tracking) -> None:
    """Delete files associated with a meta entry from the export directory."""
    data_file = entry.get("dataFileName", "")
    dir_name = entry.get("dirFileName", "")
    if dir_name:
        # After ``_restructure_notes_as_dirs``, the data file and
        # attachments live INSIDE the note's own directory.  Removing the
        # directory is sufficient; touching ``parent_dir/<dataFileName>``
        # separately would clobber an *unrelated* file at the parent
        # level (most commonly the parent note's own ``README.md``).
        p = export_dir / parent_dir / dir_name if parent_dir else export_dir / dir_name
        if p.is_dir():
            for f in p.rglob("*"):
                if f.is_file() and f.name != ".gitattributes":
                    remove_lfs_tracking(export_dir, f)
            shutil.rmtree(p)
    else:
        # Flat layout (no own directory): data file and attachments sit
        # directly in ``parent_dir``.
        if data_file:
            p = export_dir / parent_dir / data_file if parent_dir else export_dir / data_file
            if p.exists():
                remove_lfs_tracking(export_dir, p)
                p.unlink()
        for att in entry.get("attachments", []):
            adf = att.get("dataFileName", "")
            if adf:
                p = export_dir / parent_dir / adf if parent_dir else export_dir / adf
                if p.exists():
                    remove_lfs_tracking(export_dir, p)
                    p.unlink()


def apply_export_move(export_dir: Path, global_meta: dict, move: dict) -> None:
    """Move a note's entry and files from old parent to new parent in the export."""
    from .git_lfs import remove_lfs_tracking

    sync_id = move["syncId"]
    new_parent_sid = move["newParentSyncId"]
    title = move["title"]
    trilium_id = move.get("triliumNoteId")

    old_path_info = find_note_path_in_meta(global_meta, sync_id)
    if old_path_info is None:
        log("[push] ⚠ move: note not found in meta:")
        log_note_line(trilium_id, sync_id, title)
        return

    old_parent_dir, old_index = old_path_info
    old_entry = find_entry_by_sync_id(global_meta, sync_id)
    if old_entry is None:
        return

    # Find new parent's directory. ``"root"`` is the synthetic top-level
    # parent and is never present in meta as a yielded entry, so handle it
    # explicitly: moving under root means dropping straight into export_dir.
    if new_parent_sid == "root":
        new_target_dir = ""
    else:
        new_parent_path = find_note_path_in_meta(global_meta, new_parent_sid)
        new_parent_entry = find_entry_by_sync_id(global_meta, new_parent_sid)
        if new_parent_entry is None:
            log(f"[push] ⚠ move: new parent {new_parent_sid} not in meta:")
            log_note_line(trilium_id, sync_id, title)
            return
        new_parent_dir_name = new_parent_entry.get("dirFileName", "")
        if new_parent_path is not None:
            ppd, _ = new_parent_path
            new_target_dir = (
                f"{ppd}/{new_parent_dir_name}" if ppd and new_parent_dir_name
                else (new_parent_dir_name or ppd)
            )
        else:
            # Parent not in meta yet (race) — best effort: use bare dir name.
            new_target_dir = new_parent_dir_name

    old_target_dir = export_dir / old_parent_dir if old_parent_dir else export_dir
    new_target_path = export_dir / new_target_dir if new_target_dir else export_dir

    data_file = old_entry.get("dataFileName", "")
    dir_name = old_entry.get("dirFileName", "")

    # File layout depends on whether the note has its own directory:
    #
    # - When ``dir_name`` is set, ``_restructure_notes_as_dirs`` has already
    #   placed the data file (and any attachments) INSIDE that directory, so
    #   the entire directory carries everything we need; moving the directory
    #   alone is sufficient and correct.
    # - When only ``data_file`` is set (no own directory), the file lives at
    #   ``parent_dir/data_file`` and any attachments live next to it; we move
    #   each individually.
    #
    # The previous implementation moved ``data_file`` separately even when
    # ``dir_name`` was set, which a) was a no-op for restructured leaves
    # because their ``parent_dir/data_file`` doesn't exist, and b) could
    # accidentally clobber an unrelated file at the parent level (notably
    # the export's top-level README.md when moving a top-level note).
    if dir_name:
        src = old_target_dir / dir_name
        dst = new_target_path / dir_name
        if src.exists():
            ensure_dir(new_target_path)
            shutil.move(str(src), str(dst))
    elif data_file:
        src = old_target_dir / data_file
        dst = new_target_path / data_file
        if src.exists():
            ensure_dir(new_target_path)
            shutil.move(str(src), str(dst))
        for att in old_entry.get("attachments", []):
            adf = att.get("dataFileName", "")
            if adf:
                src = old_target_dir / adf
                dst = new_target_path / adf
                if src.exists():
                    shutil.move(str(src), str(dst))

    # Update meta. Caller (_apply_incremental_moves) is responsible for
    # the user-facing log line; we stay silent on success here.
    remove_entry_from_meta(global_meta, sync_id)
    insert_entry_into_meta(global_meta, new_parent_sid, old_entry)
