#!/usr/bin/env python3
"""Shared deterministic helpers for E20."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS = ROOT.parent
SURFACES = ("tui", "real_client_email")


def experiment(name: str) -> Path:
    return EXPERIMENTS / name


def physical_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def semantic_hash(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(payload).hexdigest()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def fixture_ids() -> list[str]:
    manifest = read_json(experiment("E03") / "fixture-manifest.json")
    rows = manifest.get("papers", []) + manifest.get("tasks", []) + manifest.get("adversarial", [])
    ids = [row["id"] for row in rows]
    if len(ids) != 36 or len(set(ids)) != 36:
        raise SystemExit("E20: immutable fixture count/uniqueness is not 36")
    return ids
