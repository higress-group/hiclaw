"""
Bridge: translate openclaw.json (HiClaw Worker config) into CoPaw's
config.json + providers.json, then set COPAW_WORKING_DIR so CoPaw
picks up the right workspace.
"""
from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from typing import Any


def _port_remap(url: str, is_container: bool) -> str:
    """Remap container-internal :8080 to host-exposed :18080 when needed."""
    if not is_container and url and ":8080" in url:
        return url.replace(":8080", ":18080")
    return url


def _is_in_container() -> bool:
    return Path("/.dockerenv").exists() or Path("/run/.containerenv").exists()


def _secret_dir(working_dir: Path) -> Path:
    """Return the secret dir path that copaw uses alongside working_dir."""
    return Path(str(working_dir) + ".secret")


def _patch_copaw_paths(working_dir: Path) -> None:
    """Patch copaw's module-level path constants to point at working_dir.

    copaw.constant captures WORKING_DIR / SECRET_DIR at import time from
    env vars, so setting COPAW_WORKING_DIR after import has no effect.
    We must update the live module objects directly.
    """
    secret_dir = _secret_dir(working_dir)
    secret_dir.mkdir(parents=True, exist_ok=True)

    try:
        import copaw.constant as _const
        _const.WORKING_DIR = working_dir
        _const.SECRET_DIR = secret_dir
        _const.ACTIVE_SKILLS_DIR = working_dir / "active_skills"
        _const.CUSTOMIZED_SKILLS_DIR = working_dir / "customized_skills"
        _const.MEMORY_DIR = working_dir / "memory"
        _const.CUSTOM_CHANNELS_DIR = working_dir / "custom_channels"
        _const.MODELS_DIR = working_dir / "models"
    except ImportError:
        pass

    try:
        import copaw.providers.store as _store
        _store._PROVIDERS_JSON = secret_dir / "providers.json"
        _store._LEGACY_PROVIDERS_JSON_CANDIDATES = (
            Path(__file__).resolve().parent / "providers.json",
            working_dir / "providers.json",
        )
    except ImportError:
        pass

    try:
        import copaw.envs.store as _envs
        _envs._BOOTSTRAP_WORKING_DIR = working_dir
        _envs._BOOTSTRAP_SECRET_DIR = secret_dir
        _envs._ENVS_JSON = secret_dir / "envs.json"
        _envs._LEGACY_ENVS_JSON_CANDIDATES = (working_dir / "envs.json",)
    except (ImportError, AttributeError):
        pass


def bridge_openclaw_to_copaw(
    openclaw_cfg: dict[str, Any],
    working_dir: Path,
) -> None:
    """
    Read openclaw_cfg (parsed openclaw.json) and write:
      - <working_dir>/config.json          (channels + agents)
      - <working_dir>/providers.json       (LLM credentials, for reference)
      - <working_dir>.secret/providers.json (where copaw actually reads from)

    Also sets COPAW_WORKING_DIR env var and patches copaw's module-level
    path constants so the running process uses the correct directory.
    """
    working_dir.mkdir(parents=True, exist_ok=True)
    in_container = _is_in_container()

    _write_config_json(openclaw_cfg, working_dir, in_container)
    _write_providers_json(openclaw_cfg, working_dir, in_container)

    os.environ["COPAW_WORKING_DIR"] = str(working_dir)

    # Patch module-level constants (import-time values won't reflect env change)
    _patch_copaw_paths(working_dir)

    # Copy providers.json into secret_dir — that's where copaw actually reads it
    secret_dir = _secret_dir(working_dir)
    providers_src = working_dir / "providers.json"
    if providers_src.exists():
        shutil.copy2(providers_src, secret_dir / "providers.json")


# ---------------------------------------------------------------------------
# config.json
# ---------------------------------------------------------------------------

def _write_config_json(
    cfg: dict[str, Any],
    working_dir: Path,
    in_container: bool,
) -> None:
    matrix_raw = cfg.get("channels", {}).get("matrix", {})
    homeserver = _port_remap(
        matrix_raw.get("homeserver", ""), in_container
    )
    access_token = matrix_raw.get("accessToken", "")

    # DM allowlist
    dm_cfg = matrix_raw.get("dm", {})
    dm_policy = dm_cfg.get("policy", "allowlist")
    dm_allow_from: list[str] = dm_cfg.get("allowFrom", [])

    # Group allowlist
    group_policy = matrix_raw.get("groupPolicy", "allowlist")
    group_allow_from: list[str] = matrix_raw.get("groupAllowFrom", [])

    # Per-room/group config (pass through as-is for MatrixChannel to use)
    groups = matrix_raw.get("groups", {})

    matrix_channel_cfg = {
        "enabled": matrix_raw.get("enabled", True),
        "homeserver": homeserver,
        "access_token": access_token,
        "dm_policy": dm_policy,
        "allow_from": dm_allow_from,
        "group_policy": group_policy,
        "group_allow_from": group_allow_from,
        "groups": groups,
        "filter_tool_messages": True,
        "filter_thinking": True,
    }

    config_path = working_dir / "config.json"
    # Merge with existing config to avoid clobbering other settings
    existing: dict[str, Any] = {}
    if config_path.exists():
        with open(config_path) as f:
            existing = json.load(f)

    existing.setdefault("channels", {})["matrix"] = matrix_channel_cfg
    # Disable console channel (we use Matrix)
    existing["channels"].setdefault("console", {})["enabled"] = False

    with open(config_path, "w") as f:
        json.dump(existing, f, indent=2, ensure_ascii=False)


# ---------------------------------------------------------------------------
# providers.json
# ---------------------------------------------------------------------------

def _write_providers_json(
    cfg: dict[str, Any],
    working_dir: Path,
    in_container: bool,
) -> None:
    providers_raw = cfg.get("models", {}).get("providers", {})

    custom_providers: dict[str, Any] = {}
    active_provider_id = ""
    active_model = ""

    for provider_id, provider_cfg in providers_raw.items():
        base_url = _port_remap(
            provider_cfg.get("baseUrl", ""), in_container
        )
        api_key = provider_cfg.get("apiKey", "")

        models_raw = provider_cfg.get("models", [])
        models = [
            {"id": m["id"], "name": m.get("name", m["id"])}
            for m in models_raw
            if m.get("id")
        ]

        custom_providers[provider_id] = {
            "id": provider_id,
            "name": provider_id,
            "default_base_url": base_url,
            "api_key_prefix": "",
            "models": models,
            "base_url": base_url,
            "api_key": api_key,
            "chat_model": "OpenAIChatModel",
        }

        # Use first provider + first model as active LLM
        if not active_provider_id and models:
            active_provider_id = provider_id
            active_model = models[0]["id"]

    # Resolve active model from agents.defaults.model.primary
    # Format: "provider_id/model_id"
    primary = (
        cfg.get("agents", {})
        .get("defaults", {})
        .get("model", {})
        .get("primary", "")
    )
    if primary and "/" in primary:
        pid, mid = primary.split("/", 1)
        if pid in custom_providers:
            active_provider_id = pid
            active_model = mid

    providers_data: dict[str, Any] = {
        "providers": {},
        "custom_providers": custom_providers,
        "active_llm": {
            "provider_id": active_provider_id,
            "model": active_model,
        },
    }

    providers_path = working_dir / "providers.json"
    with open(providers_path, "w") as f:
        json.dump(providers_data, f, indent=2, ensure_ascii=False)
