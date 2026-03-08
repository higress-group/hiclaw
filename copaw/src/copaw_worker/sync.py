"""MinIO file sync for copaw-worker.

Pulls openclaw.json, SOUL.md, AGENTS.md from MinIO bucket.
Runs a background loop that re-pulls on interval and calls on_pull callback.
"""
from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Any, Callable, Coroutine, Optional

import httpx

logger = logging.getLogger(__name__)


class FileSync:
    """Minimal S3-compatible MinIO client using httpx + presigned-style GET."""

    def __init__(
        self,
        endpoint: str,
        access_key: str,
        secret_key: str,
        bucket: str,
        worker_name: str,
        secure: bool = False,
        local_dir: Optional[Path] = None,
    ) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.access_key = access_key
        self.secret_key = secret_key
        self.bucket = bucket
        self.worker_name = worker_name
        self.local_dir = local_dir or Path.home() / ".copaw-worker" / worker_name
        self.local_dir.mkdir(parents=True, exist_ok=True)
        self._prefix = f"agents/{worker_name}"

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _get_object(self, key: str) -> bytes:
        """Download an object from MinIO using AWS Signature V4 via httpx."""
        import hashlib
        import hmac
        import datetime

        url = f"{self.endpoint}/{self.bucket}/{key}"
        now = datetime.datetime.utcnow()
        date_str = now.strftime("%Y%m%d")
        datetime_str = now.strftime("%Y%m%dT%H%M%SZ")

        # Build canonical request (unsigned payload for simplicity)
        host = self.endpoint.split("://", 1)[-1]
        canonical_headers = f"host:{host}\nx-amz-date:{datetime_str}\n"
        signed_headers = "host;x-amz-date"
        payload_hash = hashlib.sha256(b"").hexdigest()
        canonical_request = "\n".join([
            "GET",
            f"/{self.bucket}/{key}",
            "",
            canonical_headers,
            signed_headers,
            payload_hash,
        ])

        # String to sign
        region = "us-east-1"
        service = "s3"
        scope = f"{date_str}/{region}/{service}/aws4_request"
        string_to_sign = "\n".join([
            "AWS4-HMAC-SHA256",
            datetime_str,
            scope,
            hashlib.sha256(canonical_request.encode()).hexdigest(),
        ])

        # Signing key
        def _hmac(key: bytes, msg: str) -> bytes:
            return hmac.new(key, msg.encode(), hashlib.sha256).digest()

        signing_key = _hmac(
            _hmac(
                _hmac(
                    _hmac(f"AWS4{self.secret_key}".encode(), date_str),
                    region,
                ),
                service,
            ),
            "aws4_request",
        )
        signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

        auth = (
            f"AWS4-HMAC-SHA256 Credential={self.access_key}/{scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        )
        headers = {
            "x-amz-date": datetime_str,
            "Authorization": auth,
        }
        resp = httpx.get(url, headers=headers, timeout=30)
        resp.raise_for_status()
        return resp.content

    def _get_text(self, key: str) -> Optional[str]:
        try:
            return self._get_object(key).decode("utf-8")
        except Exception as exc:
            logger.debug("FileSync: could not fetch %s: %s", key, exc)
            return None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def get_config(self) -> dict[str, Any]:
        """Pull openclaw.json and return parsed dict."""
        text = self._get_text(f"{self._prefix}/openclaw.json")
        if not text:
            raise RuntimeError(f"openclaw.json not found in MinIO for worker {self.worker_name}")
        return json.loads(text)

    def get_soul(self) -> Optional[str]:
        return self._get_text(f"{self._prefix}/SOUL.md")

    def get_agents_md(self) -> Optional[str]:
        return self._get_text(f"{self._prefix}/AGENTS.md")

    def pull_all(self) -> list[str]:
        """Pull all known files; return list of filenames that changed."""
        changed: list[str] = []
        files = {
            "openclaw.json": f"{self._prefix}/openclaw.json",
            "SOUL.md": f"{self._prefix}/SOUL.md",
            "AGENTS.md": f"{self._prefix}/AGENTS.md",
        }
        for name, key in files.items():
            content = self._get_text(key)
            if content is None:
                continue
            local = self.local_dir / name
            existing = local.read_text() if local.exists() else None
            if content != existing:
                local.write_text(content)
                changed.append(name)
        return changed


async def sync_loop(
    sync: FileSync,
    interval: int,
    on_pull: Callable[[list[str]], Coroutine],
) -> None:
    """Background task: pull files every `interval` seconds."""
    while True:
        await asyncio.sleep(interval)
        try:
            changed = await asyncio.get_event_loop().run_in_executor(
                None, sync.pull_all
            )
            if changed:
                logger.info("FileSync: files changed: %s", changed)
                await on_pull(changed)
        except asyncio.CancelledError:
            break
        except Exception as exc:
            logger.warning("FileSync: sync error: %s", exc)
