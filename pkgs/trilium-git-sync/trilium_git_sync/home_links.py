"""Home file link rewriting and git staging.

Handles:
- Rewriting file:// links to repo-relative home/ paths (export direction)
- Rewriting home/ paths back to file:// URLs (import direction)
- Staging home files into git via plumbing commands
"""
from __future__ import annotations

import os
import json
import re
import subprocess
import urllib.parse
from pathlib import Path, PurePosixPath

from .common import ensure_dir, log, log_note_line, log_note_lines, should_lfs_track, META_FILE_NAME


# Matches file:// URLs in markdown: [text](file://...) or bare file://... in href
_FILE_LINK_RE = re.compile(
    r'(?P<prefix>\[(?:[^\]]*)\]\()'
    r'(?P<url>file://[^\s)]+)'
    r'(?P<suffix>\))'
    r'|'
    r'(?P<bare_url>file://[^\s<>"]+)'
)

# Repo-relative prefix for home files
HOME_REPO_DIR = "home"

# Matches home/... paths in markdown links or HTML attributes
_HOME_PATH_RE = re.compile(
    r'(?P<prefix>\[(?:[^\]]*)\]\()'
    r'(?P<path>home/[^\s)]+)'
    r'(?P<suffix>\))'
    r'|'
    r'(?<=href=")(?P<href_path>home/[^\s"]+)(?=")'
    r'|'
    r'(?<=src=")(?P<src_path>home/[^\s"]+)(?=")'
)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def rewrite_home_links_for_export(export_root: Path, home_dir: Path | None) -> set[str]:
    """Scan exported content for file:// links and rewrite to repo-relative home/ paths.
    Returns set of repo-relative paths to stage.
    Logs one descriptor line per note whose content references home files."""
    if not home_dir:
        return set()

    path_to_note = _build_path_to_note_descriptor(export_root)

    all_paths: set[str] = set()
    referencing_notes: dict[str, tuple[str | None, str | None, str | None]] = {}
    for file_path in sorted(export_root.rglob("*")):
        if not file_path.is_file():
            continue
        if file_path.suffix not in (".md", ".html", ".htm"):
            continue
        try:
            content = file_path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        rewritten, paths = _rewrite_links_for_export(content, home_dir)
        if paths:
            file_path.write_text(rewritten, encoding="utf-8")
            rel = file_path.relative_to(export_root).as_posix()
            descriptor = path_to_note.get(rel)
            if descriptor is None:
                descriptor = (None, None, None)
            sid = descriptor[1] or rel
            referencing_notes.setdefault(sid, descriptor)
            all_paths.update(paths)

    if all_paths:
        log(f"[home] found {len(all_paths)} file:// link(s) to home files in {len(referencing_notes)} note(s):")
        log_note_lines(referencing_notes.values())
    return all_paths


def _build_path_to_note_descriptor(
    export_root: Path,
) -> dict[str, tuple[str | None, str | None, str | None]]:
    """Build a map from export-relative file path to (triliumId, syncId, title).

    triliumId is unknown at export-time so always None; syncId is the meta noteId.
    Maps both the note's main content file and its dirFileName subtree.
    """
    meta_path = export_root / META_FILE_NAME
    if not meta_path.exists():
        return {}
    try:
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError):
        return {}

    out: dict[str, tuple[str | None, str | None, str | None]] = {}

    def walk(entries: list, parent_dir: str) -> None:
        for entry in entries:
            note_id = entry.get("noteId", "")
            title = entry.get("title")
            dir_name = entry.get("dirFileName", "")
            data_file = entry.get("dataFileName", "")
            entry_dir = f"{parent_dir}/{dir_name}" if parent_dir and dir_name else (dir_name or parent_dir)
            if note_id and note_id != "root":
                descriptor = (None, note_id, title)
                if data_file:
                    if dir_name:
                        out[f"{entry_dir}/{data_file}"] = descriptor
                    elif parent_dir:
                        out[f"{parent_dir}/{data_file}"] = descriptor
                    else:
                        out[data_file] = descriptor
                if entry_dir:
                    out.setdefault(entry_dir, descriptor)
            if entry.get("children"):
                walk(entry["children"], entry_dir)

    walk(meta.get("files", []), "")
    return out


def rewrite_home_links_for_import(export_dir: Path, home_dir: Path | None) -> None:
    """Rewrite repo-relative home/ paths back to file:// URLs in content files."""
    if not home_dir:
        return

    for file_path in sorted(export_dir.rglob("*")):
        if not file_path.is_file():
            continue
        if file_path.suffix not in (".md", ".html", ".htm"):
            continue
        try:
            content = file_path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        rewritten = _rewrite_links_for_import(content, home_dir)
        if rewritten != content:
            file_path.write_text(rewritten, encoding="utf-8")


def stage_home_files_post_commit(worktree: Path, home_paths: set[str], config) -> None:
    """Stage home files into the git index and amend the commit."""
    from git import Repo

    staged: set[str] = set()
    for repo_rel in sorted(home_paths):
        if not repo_rel.startswith(HOME_REPO_DIR + "/"):
            continue
        rel_to_home = repo_rel[len(HOME_REPO_DIR) + 1:]
        abs_path = config.home_dir.resolve() / rel_to_home

        if not abs_path.is_file():
            log(f"[home] ⚠ referenced file not found: {abs_path}")
            continue

        if config.use_lfs and should_lfs_track(abs_path):
            _stage_lfs_file(worktree, repo_rel, abs_path)
        else:
            _stage_regular_file(worktree, repo_rel, abs_path)
        staged.add(repo_rel)

    if staged:
        log(f"[home] staged {len(staged)} home file(s)")
        repo = Repo(str(worktree))
        repo.git.add("--sparse", "-A", "--", "home/")
        repo.git.commit("--amend", "--no-edit")


# ---------------------------------------------------------------------------
# Link resolution
# ---------------------------------------------------------------------------

def _resolve_file_url(url: str, home_dir: Path) -> Path | None:
    """Resolve a file:// URL to an absolute Path, or None if not under home_dir."""
    if url.startswith("file:///"):
        raw_path = url[len("file://"):]
    elif url.startswith("file://~/"):
        raw_path = str(home_dir / url[len("file://~/"):])
    elif url.startswith("file://~"):
        return None
    else:
        return None

    decoded = urllib.parse.unquote(raw_path)
    resolved = Path(decoded).resolve()

    try:
        resolved.relative_to(home_dir.resolve())
    except ValueError:
        return None

    return resolved


def _path_to_repo_relative(file_path: Path, home_dir: Path) -> str:
    """Convert absolute path to repo-relative path under HOME_REPO_DIR."""
    rel = file_path.relative_to(home_dir.resolve())
    return f"{HOME_REPO_DIR}/{rel.as_posix()}"


def _repo_relative_to_file_url(repo_path: str, home_dir: Path) -> str:
    """Convert a repo-relative 'home/...' path back to a file:// URL."""
    if repo_path.startswith(HOME_REPO_DIR + "/"):
        rel = repo_path[len(HOME_REPO_DIR) + 1:]
    else:
        rel = repo_path
    abs_path = home_dir / rel
    encoded = urllib.parse.quote(str(abs_path), safe="/:")
    return f"file://{encoded}"


# ---------------------------------------------------------------------------
# Link rewriting internals
# ---------------------------------------------------------------------------

def _rewrite_links_for_export(content: str, home_dir: Path) -> tuple[str, set[str]]:
    """Rewrite file:// links to repo-relative paths in markdown content."""
    referenced_paths: set[str] = set()

    def replace_match(m: re.Match) -> str:
        if m.group("prefix"):
            url = m.group("url")
            resolved = _resolve_file_url(url, home_dir)
            if resolved and resolved.is_file():
                repo_rel = _path_to_repo_relative(resolved, home_dir)
                referenced_paths.add(repo_rel)
                return f"{m.group('prefix')}{repo_rel}{m.group('suffix')}"
            return m.group(0)
        else:
            url = m.group("bare_url")
            resolved = _resolve_file_url(url, home_dir)
            if resolved and resolved.is_file():
                repo_rel = _path_to_repo_relative(resolved, home_dir)
                referenced_paths.add(repo_rel)
                return repo_rel
            return m.group(0)

    rewritten = _FILE_LINK_RE.sub(replace_match, content)
    return rewritten, referenced_paths


def _rewrite_links_for_import(content: str, home_dir: Path) -> str:
    """Rewrite repo-relative 'home/...' paths back to file:// URLs."""

    def replace_match(m: re.Match) -> str:
        if m.group("prefix"):
            path = m.group("path")
            file_url = _repo_relative_to_file_url(path, home_dir)
            return f"{m.group('prefix')}{file_url}{m.group('suffix')}"
        path = m.group("href_path") or m.group("src_path")
        if path:
            return _repo_relative_to_file_url(path, home_dir)
        return m.group(0)

    return _HOME_PATH_RE.sub(replace_match, content)


# ---------------------------------------------------------------------------
# Home file git staging
# ---------------------------------------------------------------------------

def _stage_regular_file(worktree: Path, repo_path: str, abs_path: Path) -> None:
    """Stage a regular file via git hash-object + update-index."""
    result = subprocess.run(
        ["git", "hash-object", "-w", "--", str(abs_path)],
        cwd=worktree, capture_output=True, text=True, check=True,
    )
    blob_sha = result.stdout.strip()
    mode = "100755" if os.access(abs_path, os.X_OK) else "100644"
    subprocess.run(
        ["git", "update-index", "--add", "--cacheinfo", f"{mode},{blob_sha},{repo_path}"],
        cwd=worktree, capture_output=True, text=True, check=True,
    )
    log(f"[home] staged: {repo_path} ({_human_size(abs_path.stat().st_size)})")

def _stage_lfs_file(worktree: Path, repo_path: str, abs_path: Path) -> None:
    """Stage a file as an LFS pointer via git-lfs pointer + hash-object."""
    result = subprocess.run(
        ["git", "lfs", "pointer", "--file", str(abs_path)],
        cwd=worktree, capture_output=True, text=True,
    )

    pointer_content = ""
    if result.returncode == 0:
        in_pointer = False
        for line in result.stdout.splitlines(keepends=True):
            if line.startswith("version https://git-lfs"):
                in_pointer = True
            if in_pointer:
                pointer_content += line

    if not pointer_content.startswith("version https://git-lfs"):
        log(f"[home] ⚠ LFS pointer generation failed for {repo_path}, staging directly")
        _stage_regular_file(worktree, repo_path, abs_path)
        return

    with open(abs_path, "rb") as f:
        subprocess.run(
            ["git", "lfs", "clean"],
            stdin=f, cwd=worktree, capture_output=True, check=True,
        )

    hash_result = subprocess.run(
        ["git", "hash-object", "-w", "--stdin"],
        input=pointer_content, cwd=worktree,
        capture_output=True, text=True, check=True,
    )
    blob_sha = hash_result.stdout.strip()

    subprocess.run(
        ["git", "update-index", "--add", "--cacheinfo", f"100644,{blob_sha},{repo_path}"],
        cwd=worktree, capture_output=True, text=True, check=True,
    )

    _ensure_home_lfs_attribute(worktree, repo_path)
    log(f"[home] staged (LFS): {repo_path} ({_human_size(abs_path.stat().st_size)})")


def _ensure_home_lfs_attribute(worktree: Path, repo_path: str) -> None:
    """Ensure .gitattributes in the home file's directory tracks it for LFS."""
    from .git_lfs import _read_lfs_entries, _write_lfs_entries

    repo_rel = PurePosixPath(repo_path)
    attr_dir = worktree / repo_rel.parent
    ensure_dir(attr_dir)
    attr_path = attr_dir / ".gitattributes"

    entries = _read_lfs_entries(attr_path)
    filename = repo_rel.name
    if filename not in entries:
        entries.add(filename)
        _write_lfs_entries(attr_path, entries)


def _human_size(size: int) -> str:
    """Format byte size for logging."""
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024:
            return f"{size:.0f}{unit}" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}TB"
