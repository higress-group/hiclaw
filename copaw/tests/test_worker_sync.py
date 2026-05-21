"""Tests for CoPaw worker file sync behavior."""

from copaw_worker import sync
from copaw_worker.sync import FileSync


def test_ensure_alias_skips_static_alias_in_k8s_mode(monkeypatch, tmp_path):
    calls = []

    monkeypatch.setenv("HICLAW_RUNTIME", "k8s")
    monkeypatch.setattr(sync, "_mc", lambda *args, **_kwargs: calls.append(args))

    fs = FileSync(
        endpoint="minio:9000",
        access_key="tt",
        secret_key="secret",
        bucket="hiclaw",
        worker_name="tt",
        local_dir=tmp_path,
    )

    fs._ensure_alias()

    assert fs._alias_set is True
    assert calls == []
