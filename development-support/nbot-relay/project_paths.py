"""Resolve fork-local deployment paths without embedding a developer's machine."""

import json
import os
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
CONFIG = PROJECT / "deployment.local.json"


def configuration():
    if not CONFIG.exists():
        return {}
    value = json.loads(CONFIG.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict) or value.get("schema") != "auto-starve/deployment@1":
        raise ValueError("Invalid deployment.local.json; run python deploy.py configure --game-dir PATH")
    return value


def resolve_path(value, name):
    if not isinstance(value, str) or not value.strip() or "<" in value or ">" in value:
        raise ValueError(name + " must be configured locally; run python deploy.py configure --game-dir PATH")
    path = Path(value).expanduser()
    return (path if path.is_absolute() else PROJECT / path).resolve()


def game_dir():
    return resolve_path(os.environ.get("DST_GAME_DIR") or configuration().get("game_dir"), "game_dir")


def native_scripts():
    value = os.environ.get("DST_SCRIPTS_DIR") or configuration().get("scripts_dir")
    return resolve_path(value, "scripts_dir") if value else game_dir() / "data/databundles/scripts"


def storage_root():
    value = os.environ.get("WILSON_STORAGE_ROOT") or configuration().get("storage_root", ".local/dst")
    path = resolve_path(value, "storage_root")
    if path == PROJECT or PROJECT.is_relative_to(path) or game_dir().is_relative_to(path):
        raise ValueError("storage_root must be a dedicated directory, not the repository, game directory or their ancestor")
    return path
