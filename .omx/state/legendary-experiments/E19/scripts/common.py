#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CANDIDATE_ID = "candidate-lossless-semantic-tree"
SURFACES = ("authenticated_studio", "public_reader", "cli_api")


def state_root() -> Path:
    local = ROOT.parents[1]
    if (local / "legendary-experiments" / "round-06-plan" / "assignments.json").is_file():
        return local
    configured = os.environ.get("OMX_TEAM_STATE_ROOT")
    return Path(configured) if configured else local


def experiment_root(name: str) -> Path:
    return state_root() / "legendary-experiments" / name


def physical_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def semantic_hash(value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def fixtures() -> list[dict[str, Any]]:
    manifest = json.loads((experiment_root("E03") / "fixture-manifest.json").read_text())
    rows = manifest["papers"] + manifest["tasks"] + manifest["adversarial"]
    if len(rows) != 36 or len({row["id"] for row in rows}) != 36:
        raise SystemExit(f"E19 INPUT FAIL: expected 36 unique fixtures, got {len(rows)}")
    return sorted(rows, key=lambda row: row["id"])


def capsules() -> dict[str, dict[str, Any]]:
    path = experiment_root("E16") / "output" / "capsules.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines() if line]
    if len(rows) != 36 or len({row["fixture_id"] for row in rows}) != 36:
        raise SystemExit(f"E19 INPUT FAIL: expected 36 unique E16 capsules, got {len(rows)}")
    return {row["fixture_id"]: row for row in rows}
