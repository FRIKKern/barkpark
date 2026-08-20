#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SURFACES = (
    "authenticated_studio",
    "public_reader",
    "tui",
    "real_client_email",
    "cli_api",
)
CANDIDATE_ID = "candidate-lossless-semantic-tree"


def state_root() -> Path:
    configured = os.environ.get("OMX_TEAM_STATE_ROOT")
    if configured:
        return Path(configured)
    return ROOT.parents[1]


def e16_root() -> Path:
    return state_root() / "legendary-experiments" / "E16"


def e11_root() -> Path:
    return state_root() / "legendary-experiments" / "E11"


def physical_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def semantic_hash(value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def load_capsules() -> list[dict[str, Any]]:
    path = e16_root() / "output" / "capsules.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines() if line]
    if len(rows) != 36:
        raise SystemExit(f"E17 INPUT FAIL: expected 36 E16 capsules, got {len(rows)}")
    return rows


def target_slug(fixture_id: str) -> str:
    return f"{CANDIDATE_ID}--{fixture_id}"
