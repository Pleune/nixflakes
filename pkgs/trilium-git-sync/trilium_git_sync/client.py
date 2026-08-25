"""Trilium ETAPI HTTP client using requests."""
from __future__ import annotations

import getpass
import json
import os
import shlex
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import quote

import requests

from .common import ensure_private_dir, env_or, log


class HttpError(RuntimeError):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class TriliumClient:
    def __init__(self, base_url: str, state_dir: Path, token_name: str, executable_name: str = "trilium-git-sync"):
        self.base_url = base_url.rstrip("/")
        self.state_dir = state_dir
        self.token_name = token_name
        self.executable_name = executable_name
        self.cached_token_path = self.state_dir / "auth-token"
        self.token = env_or("TRILIUM_GIT_SYNC_AUTH_TOKEN") or env_or("TRILIUM_ETAPI_TOKEN") or self._read_cached_token()
        self.password = env_or("TRILIUM_GIT_SYNC_PASSWORD") or env_or("TRILIUM_PASSWORD")
        self.timeout = float(env_or("TRILIUM_GIT_SYNC_HTTP_TIMEOUT_SECONDS", "2") or "2")
        self._session = requests.Session()

    def _read_cached_token(self) -> str | None:
        if not self.cached_token_path.exists():
            return None
        ensure_private_dir(self.cached_token_path.parent)
        if self.cached_token_path.exists():
            os.chmod(self.cached_token_path, 0o600)
        token = self.cached_token_path.read_text().strip()
        return token or None

    def _write_cached_token(self, token: str) -> None:
        ensure_private_dir(self.cached_token_path.parent)
        fd, tmp_path = tempfile.mkstemp(
            dir=str(self.cached_token_path.parent),
            prefix=f".{self.cached_token_path.name}.",
            text=True,
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(token + "\n")
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, self.cached_token_path)
            if self.cached_token_path.exists():
                os.chmod(self.cached_token_path, 0o600)
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    def _request(
        self,
        method: str,
        path: str,
        *,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> bytes:
        url = self.base_url + path
        try:
            resp = self._session.request(
                method, url, data=data, headers=headers or {},
                timeout=timeout or self.timeout,
            )
        except (requests.ConnectionError, requests.Timeout) as exc:
            raise RuntimeError(
                f"Trilium API request timed out or failed after {timeout or self.timeout:g}s: {method} {path}"
            ) from exc
        if resp.status_code >= 400:
            raise HttpError(resp.status_code, resp.text)
        return resp.content

    def _authed(
        self,
        method: str,
        path: str,
        *,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> bytes:
        if not self.token:
            raise HttpError(401, "No Trilium auth token is available")
        merged = {"Authorization": f"Bearer {self.token}", **(headers or {})}
        return self._request(method, path, data=data, headers=merged, timeout=timeout)

    def _api_json(self, method: str, path: str, *, body: Any | None = None, timeout: float | None = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json"} if data else {}
        raw = self._authed(method, path, data=data, headers=headers, timeout=timeout)
        return json.loads(raw) if raw else None

    def _api_bytes(self, method: str, path: str, *, data: bytes | None = None, headers: dict[str, str] | None = None, timeout: float | None = None) -> bytes:
        return self._authed(method, path, data=data, headers=headers, timeout=timeout)

    # ------------------------------------------------------------------
    # Auth
    # ------------------------------------------------------------------

    def _mint_token_from_password(self) -> str | None:
        if not self.password:
            return None
        raw = self._request(
            "POST", "/api/login/token",
            data=json.dumps({"password": self.password, "tokenName": self.token_name}).encode(),
            headers={"Content-Type": "application/json"},
        )
        token = json.loads(raw)["token"]
        self.token = token
        self._write_cached_token(token)
        return token

    def mint_token_interactive(self) -> str:
        password = getpass.getpass(f"Trilium password for {self.base_url}: ")
        if not password:
            raise RuntimeError("No password entered")
        self.password = password
        token = self._mint_token_from_password()
        if token is None:
            raise RuntimeError("Failed to mint Trilium API token")
        return token

    def mint_token_command(self) -> str:
        args = [
            self.executable_name, "--mint-token",
            "--base-url", self.base_url,
            "--state-dir", str(self.state_dir),
            "--token-name", self.token_name,
        ]
        return " ".join(shlex.quote(arg) for arg in args)

    # ------------------------------------------------------------------
    # Export / Import
    # ------------------------------------------------------------------

    def export_markdown_zip(self, note_id: str, timeout: int | None = 120) -> bytes | None:
        path = f"/etapi/notes/{quote(note_id, safe='')}/export?format=markdown"
        log(f"requesting markdown export for note {note_id}")
        try:
            return self._api_bytes("GET", path, timeout=timeout)
        except HttpError as exc:
            if exc.status != 401:
                raise
            token = self._mint_token_from_password()
            if token:
                return self._api_bytes("GET", path, timeout=timeout)
            log("skipping sync because no auth token/password is configured")
            log(f"mint an API token interactively with: {self.mint_token_command()}")
            return None

    def import_zip(self, note_id: str, archive_bytes: bytes, timeout: int | None = None) -> dict[str, Any] | None:
        try:
            raw = self._api_bytes(
                "POST", f"/etapi/notes/{quote(note_id, safe='')}/import",
                data=archive_bytes,
                headers={"Content-Type": "application/octet-stream"},
                timeout=timeout,
            )
            return json.loads(raw)
        except RuntimeError as exc:
            if "timed out" in str(exc).lower():
                log(f"import request timed out ({timeout}s) — partial import likely succeeded")
                return None
            raise
        except HttpError as exc:
            log(f"import returned HTTP {exc.status}: {exc}")
            return None

    # ------------------------------------------------------------------
    # Notes
    # ------------------------------------------------------------------

    def get_note(self, note_id: str) -> dict[str, Any] | None:
        try:
            return self._api_json("GET", f"/etapi/notes/{quote(note_id, safe='')}")
        except HttpError as exc:
            if exc.status == 404:
                return None
            raise

    def get_note_content(self, note_id: str) -> str:
        return self._api_bytes("GET", f"/etapi/notes/{quote(note_id, safe='')}/content").decode()

    def patch_note(self, note_id: str, body: dict[str, Any]) -> dict[str, Any]:
        return self._api_json("PATCH", f"/etapi/notes/{quote(note_id, safe='')}", body=body)

    def put_note_content(self, note_id: str, content: str, mime: str | None = None) -> None:
        ct = mime or "text/html"
        if "charset" not in ct:
            ct += "; charset=utf-8"
        self._api_bytes("PUT", f"/etapi/notes/{quote(note_id, safe='')}/content",
                        data=content.encode(), headers={"Content-Type": ct})

    def put_note_content_bytes(self, note_id: str, data: bytes, mime: str | None = None) -> None:
        self._api_bytes("PUT", f"/etapi/notes/{quote(note_id, safe='')}/content",
                        data=data, headers={"Content-Type": mime or "application/octet-stream"})

    def create_note(self, body: dict[str, Any]) -> dict[str, Any]:
        return self._api_json("POST", "/etapi/create-note", body=body)

    def delete_note(self, note_id: str) -> None:
        self._api_bytes("DELETE", f"/etapi/notes/{quote(note_id, safe='')}")

    # ------------------------------------------------------------------
    # Attributes
    # ------------------------------------------------------------------

    def create_attribute(self, body: dict[str, Any]) -> dict[str, Any]:
        return self._api_json("POST", "/etapi/attributes", body=body)

    def delete_attribute(self, attribute_id: str) -> None:
        self._api_bytes("DELETE", f"/etapi/attributes/{quote(attribute_id, safe='')}")

    # ------------------------------------------------------------------
    # Attachments
    # ------------------------------------------------------------------

    def create_attachment(self, body: dict[str, Any]) -> dict[str, Any]:
        return self._api_json("POST", "/etapi/attachments", body=body)

    def patch_attachment(self, attachment_id: str, body: dict[str, Any]) -> dict[str, Any]:
        return self._api_json("PATCH", f"/etapi/attachments/{quote(attachment_id, safe='')}", body=body)

    def get_attachment(self, attachment_id: str) -> dict[str, Any]:
        return self._api_json("GET", f"/etapi/attachments/{quote(attachment_id, safe='')}")

    def get_attachment_content(self, attachment_id: str) -> bytes:
        return self._api_bytes("GET", f"/etapi/attachments/{quote(attachment_id, safe='')}/content")

    def put_attachment_content(self, attachment_id: str, content: bytes, mime: str | None = None) -> None:
        headers = {"Content-Type": mime} if mime else {}
        self._api_bytes("PUT", f"/etapi/attachments/{quote(attachment_id, safe='')}/content",
                        data=content, headers=headers)

    def delete_attachment(self, attachment_id: str) -> None:
        self._api_bytes("DELETE", f"/etapi/attachments/{quote(attachment_id, safe='')}")

    # ------------------------------------------------------------------
    # Branches
    # ------------------------------------------------------------------

    def get_branch(self, branch_id: str) -> dict[str, Any]:
        return self._api_json("GET", f"/etapi/branches/{quote(branch_id, safe='')}")

    def create_branch(self, body: dict[str, Any]) -> dict[str, Any]:
        """Create a branch (clone a note into a parent)."""
        return self._api_json("POST", "/etapi/branches", body=body)

    def delete_branch(self, branch_id: str) -> None:
        self._api_bytes("DELETE", f"/etapi/branches/{quote(branch_id, safe='')}")

    def patch_branch(self, branch_id: str, body: dict[str, Any]) -> dict[str, Any]:
        return self._api_json("PATCH", f"/etapi/branches/{quote(branch_id, safe='')}", body=body)

    def refresh_note_ordering(self, parent_note_id: str) -> None:
        self._api_bytes("POST", f"/etapi/refresh-note-ordering/{quote(parent_note_id, safe='')}")
