from __future__ import annotations

import os
import sys
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any

try:
    import fcntl
except ImportError:  # pragma: no cover
    fcntl = None


META_FILE_NAME = "!!!meta.json"
LFS_MANAGED_BEGIN = "# BEGIN trilium-git-sync git-lfs"
LFS_MANAGED_END = "# END trilium-git-sync git-lfs"


def log(message: str) -> None:
    timestamp = datetime.now().isoformat(timespec="seconds")
    print(f"[{timestamp}] trilium-git-sync: {message}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Note-line formatting
#
# Standard one-line descriptor for a note when reporting detected changes,
# commits, deletions, re-imports, or any other per-note operation. The format
# is: "  - [trilium:<tid> sync:<sid>] <title>"
# with explicit placeholders for missing fields:
#   - missing trilium id  -> <unknown>
#   - missing sync id     -> <untagged>
#   - missing title       -> <unknown>
# ---------------------------------------------------------------------------

_UNKNOWN_TRILIUM_ID = "<unknown>"
_UNKNOWN_SYNC_ID = "<untagged>"
_UNKNOWN_TITLE = "<unknown>"


def format_note_line(
    trilium_id: str | None,
    sync_id: str | None,
    title: str | None,
    marker: str = "-",
    suffix: str = "",
) -> str:
    """Return one-note descriptor line for logging.

    Always renders all three identifiers in a stable order so listings are
    grep-friendly. Pass ``suffix`` to append per-line context (e.g. parent
    or change kind).
    """
    tid = trilium_id if trilium_id else _UNKNOWN_TRILIUM_ID
    sid = sync_id if sync_id else _UNKNOWN_SYNC_ID
    t = title if title not in (None, "") else _UNKNOWN_TITLE
    line = f"  {marker} [trilium:{tid} sync:{sid}] {t}"
    if suffix:
        line = f"{line} {suffix}"
    return line


def log_note_line(
    trilium_id: str | None,
    sync_id: str | None,
    title: str | None,
    marker: str = "-",
    suffix: str = "",
) -> None:
    log(format_note_line(trilium_id, sync_id, title, marker=marker, suffix=suffix))


def log_note_lines(notes, marker: str = "-") -> None:
    """Log a list of note descriptors, one per line.

    Each item may be either:
    - a tuple ``(trilium_id, sync_id, title)`` or ``(trilium_id, sync_id, title, suffix)``
    - a dict with keys ``triliumId`` / ``triliumNoteId``, ``syncId``, ``title``,
      and optional ``suffix``
    """
    for n in notes:
        if isinstance(n, dict):
            tid = n.get("triliumId") or n.get("triliumNoteId")
            sid = n.get("syncId")
            title = n.get("title")
            suffix = n.get("suffix", "")
            log_note_line(tid, sid, title, marker=marker, suffix=suffix)
        else:
            tid, sid, title, *rest = (*n, "") if len(n) == 3 else n
            suffix = rest[0] if rest else ""
            log_note_line(tid, sid, title, marker=marker, suffix=suffix)


def env_or(name: str, fallback: str | None = None) -> str | None:
    value = os.environ.get(name)
    return fallback if value in {None, ""} else value


def env_flag(name: str, default: bool = False) -> bool:
    value = env_or(name)
    return default if value is None else value.lower() in {"1", "true", "yes", "on"}


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def ensure_private_dir(path: Path) -> None:
    ensure_dir(path)
    os.chmod(path, 0o700)



# Files above this size are always LFS-tracked regardless of content
LFS_SIZE_THRESHOLD = 100 * 1024  # 100 KB


def should_lfs_track(path: Path) -> bool:
    """Determine if a file should be LFS-tracked: binary content OR large size."""
    try:
        if path.stat().st_size > LFS_SIZE_THRESHOLD:
            return True
        return is_binary_file(path)
    except OSError:
        return False


def is_binary_file(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            chunk = f.read(1024 * 1024)  # read at most 1MB
        if not chunk:
            return False
        if b"\0" in chunk:
            return True
        text_bytes = bytearray({7, 8, 9, 10, 12, 13, 27} | set(range(0x20, 0x7F)))
        return (len(chunk.translate(None, text_bytes)) / len(chunk)) > 0.30
    except OSError:
        return False



def posix_join(*parts: str) -> str:
    cleaned = [part for part in parts if part not in ("", ".")]
    return "" if not cleaned else str(PurePosixPath(*cleaned))



class Lock:
    def __init__(self, path: Path):
        self.path = path
        self.handle = None

    def __enter__(self):
        ensure_dir(self.path.parent)
        self.handle = self.path.open("w")
        if fcntl is not None:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> bool:
        if self.handle is not None:
            if fcntl is not None:
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close()
        return False
