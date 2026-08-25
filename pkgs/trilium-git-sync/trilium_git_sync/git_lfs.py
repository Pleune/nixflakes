"""Git LFS tracking helpers.

Manages per-directory .gitattributes with a managed block,
binary/size detection, and LFS smudge operations.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from git import Repo

from .common import (
    LFS_MANAGED_BEGIN,
    LFS_MANAGED_END,
    ensure_dir,
    log,
    should_lfs_track,
)


# ---------------------------------------------------------------------------
# .gitattributes managed block read/write
# ---------------------------------------------------------------------------

def strip_managed_lfs_block(content: str) -> str:
    pattern = re.compile(rf"\n?{re.escape(LFS_MANAGED_BEGIN)}\n.*?\n{re.escape(LFS_MANAGED_END)}\n?", re.DOTALL)
    return pattern.sub("\n", content).strip("\n")


def _read_lfs_entries(attr_path: Path) -> set[str]:
    """Read existing LFS-tracked filenames from a .gitattributes managed block."""
    if not attr_path.exists():
        return set()
    content = attr_path.read_text()
    match = re.search(
        rf"{re.escape(LFS_MANAGED_BEGIN)}\n(.+?)\n{re.escape(LFS_MANAGED_END)}",
        content, re.DOTALL,
    )
    if not match:
        return set()
    entries = set()
    for line in match.group(1).splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('"'):
            i = 1
            raw_chars: list[str] = []
            while i < len(line):
                if line[i] == '\\' and i + 1 < len(line):
                    raw_chars.append(line[i + 1])
                    i += 2
                elif line[i] == '"':
                    break
                else:
                    raw_chars.append(line[i])
                    i += 1
            entries.add(''.join(raw_chars))
        else:
            token = line.split()[0]
            if token.startswith('\\!'):
                token = '!' + token[2:]
            entries.add(token)
    return entries


def _write_lfs_entries(attr_path: Path, entries: set[str]) -> None:
    """Write the managed LFS block to a .gitattributes file."""
    existing = attr_path.read_text() if attr_path.exists() else ""
    stripped = strip_managed_lfs_block(existing)
    sorted_entries = sorted(entries)

    if sorted_entries:
        block = "\n".join([
            LFS_MANAGED_BEGIN,
            *(f"{escape_gitattributes_pattern(name)} filter=lfs diff=lfs merge=lfs -text" for name in sorted_entries),
            LFS_MANAGED_END,
        ])
        sections = [part for part in [stripped, block] if part]
        new_content = "\n\n".join(sections).strip()
        ensure_dir(attr_path.parent)
        attr_path.write_text(new_content + "\n")
    elif stripped:
        attr_path.write_text(stripped + "\n")
    elif attr_path.exists():
        attr_path.unlink()


# ---------------------------------------------------------------------------
# Pattern escaping
# ---------------------------------------------------------------------------

def escape_gitattributes_pattern(name: str) -> str:
    """Escape a filename for use in .gitattributes."""
    needs_quoting = any(c in name for c in ' \t#"![\\') or name.startswith('!')
    if not needs_quoting:
        return name
    escaped = name.replace("\\", "\\\\").replace('"', '\\"')
    if escaped.startswith('!'):
        escaped = '\\!' + escaped[1:]
    return f'"{escaped}"'


# ---------------------------------------------------------------------------
# LFS tracking operations
# ---------------------------------------------------------------------------

def ensure_lfs_tracked(export_dir: Path, file_path: Path) -> bool:
    """Add a file to its directory's .gitattributes if it qualifies for LFS."""
    if not should_lfs_track(file_path):
        return False
    attr_path = file_path.parent / ".gitattributes"
    entries = _read_lfs_entries(attr_path)
    if file_path.name in entries:
        return True
    entries.add(file_path.name)
    _write_lfs_entries(attr_path, entries)
    log(f"[lfs] tracking: {file_path.relative_to(export_dir)}")
    return True


def remove_lfs_tracking(export_dir: Path, file_path: Path) -> None:
    """Remove a file's LFS entry from .gitattributes when the file is deleted."""
    attr_path = file_path.parent / ".gitattributes"
    entries = _read_lfs_entries(attr_path)
    if file_path.name not in entries:
        return
    entries.discard(file_path.name)
    _write_lfs_entries(attr_path, entries)
    log(f"[lfs] untracking: {file_path.relative_to(export_dir)}")


def sync_lfs_attributes(export_dir: Path, enabled: bool, restricted_dirs: set[str] | None = None) -> set[str]:
    """Ensure LFS-qualifying files are tracked. Returns set of touched directories."""
    if not enabled or not export_dir.exists():
        return set()

    touched: set[str] = set()

    if restricted_dirs is not None:
        dirs_to_scan = sorted(restricted_dirs)
    else:
        dirs_to_scan = None

    def _scan_dir(dir_path: Path) -> None:
        for path in sorted(dir_path.rglob("*")):
            if not path.is_file() or path.name == ".gitattributes":
                continue
            if should_lfs_track(path):
                attr_path = path.parent / ".gitattributes"
                entries = _read_lfs_entries(attr_path)
                if path.name not in entries:
                    entries.add(path.name)
                    _write_lfs_entries(attr_path, entries)
                    rel_dir = path.parent.relative_to(export_dir).as_posix() if path.parent != export_dir else ""
                    touched.add(rel_dir)
                    log(f"[lfs] tracking: {path.relative_to(export_dir)}")

    if dirs_to_scan is not None:
        for rel_dir in dirs_to_scan:
            dir_path = export_dir if rel_dir == "" else export_dir / rel_dir
            if dir_path.exists() and dir_path.is_dir():
                _scan_dir(dir_path)
    else:
        _scan_dir(export_dir)

    return touched


def ensure_git_lfs(checkout: Path) -> None:
    log("ensuring git-lfs is configured for this checkout")
    repo = Repo(str(checkout))
    repo.git.lfs("install", "--local")


def lfs_pull_and_smudge(worktree: Path, directory: Path) -> None:
    """Pull LFS objects and smudge any remaining pointer files in directory.

    Temporarily clears GIT_LFS_SKIP_SMUDGE so that `git lfs pull` works,
    then restores the previous value.
    """
    from git import GitCommandError as _GitError

    old_val = os.environ.pop("GIT_LFS_SKIP_SMUDGE", None)
    try:
        log("[lfs] pulling objects")
        repo = Repo(str(worktree))
        try:
            repo.git.lfs("pull")
        except _GitError:
            pass
        smudge_lfs_pointers(directory)
    finally:
        if old_val is not None:
            os.environ["GIT_LFS_SKIP_SMUDGE"] = old_val


# ---------------------------------------------------------------------------
# LFS smudge
# ---------------------------------------------------------------------------

def smudge_lfs_pointers(directory: Path) -> None:
    """Find remaining LFS pointer files and replace them with actual content."""
    for file in directory.rglob("*"):
        if not file.is_file():
            continue
        if file.stat().st_size > 200:
            continue
        try:
            content = file.read_bytes()
        except OSError:
            continue
        if not content.startswith(b"version https://git-lfs"):
            continue
        result = subprocess.run(
            ["git", "lfs", "smudge"],
            input=content,
            capture_output=True,
            cwd=str(directory),
        )
        if result.returncode == 0 and len(result.stdout) > 200:
            file.write_bytes(result.stdout)
            log(f"[lfs] smudged {file.relative_to(directory)}")
