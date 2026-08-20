#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS = ROOT.parent
FIXTURES = EXPERIMENTS / "E03" / "fixture-manifest.json"
CAPSULES = EXPERIMENTS / "E16" / "output" / "capsules.jsonl"
E19_RESULT = EXPERIMENTS / "E19" / "result.json"
PINNED = {
    "E03/fixture-manifest.json": "0ab24d0a38f9d8db97073accaea37f02786d9c47f7dac3471e858907d5c308df",
    "E16/output/capsules.jsonl": "3c8aa851df6d7cb65bba42f6322af82e08f6af2621499c5ecea66f11644f1830",
    "E19/result.json": "3c2228fe964aedbbc7ebd881d16f03144a6d9e6fee390b75b371189f62d60ad6",
}
ENV_NAMES = ("E22_ISOLATED_BASE_URL", "E22_DATABASE_URL", "E22_ADMIN_TOKEN")
SURFACES = ("authenticated_studio", "public_reader", "cli")
CANDIDATE_ID = "candidate-lossless-semantic-tree"
CANDIDATE_DIGEST = PINNED["E16/output/capsules.jsonl"]


def pinned_path(relative: str) -> Path:
    return EXPERIMENTS / relative
PRODUCTION_HOSTS = {
    "api.barkpark.cloud", "guerrilla.barkpark.cloud", "barkpark.cloud",
    "89.167.28.206", "157.180.90.121",
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def physical_hash(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(value))


def read_json(path: Path) -> object:
    return json.loads(path.read_text())


def fixture_ids() -> list[str]:
    data = read_json(FIXTURES)
    ids = [r["id"] for key in ("papers", "tasks", "adversarial") for r in data[key]]
    require(len(ids) == len(set(ids)) == 36, "frozen fixture inventory must be exactly 36 unique ids")
    return ids


def capsules() -> list[dict]:
    rows = [json.loads(line) for line in CAPSULES.read_text().splitlines() if line.strip()]
    require(len(rows) == 36, "capsule inventory must be exactly 36")
    require({r["fixture_id"] for r in rows} == set(fixture_ids()), "fixture/capsule identity drift")
    require({r["candidate_id"] for r in rows} == {CANDIDATE_ID}, "candidate id drift")
    return rows


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def safe_slug(value: str) -> str:
    clean = re.sub(r"[^a-z0-9-]+", "-", value.lower()).strip("-")
    return clean[:72] or sha256_bytes(value.encode())[:16]


def classify_runtime(ttl_minutes: int, deny_production: bool = True) -> dict:
    require(1 <= ttl_minutes <= 120, "TTL must be between 1 and 120 minutes")
    values = {name: os.environ.get(name, "") for name in ENV_NAMES}
    presence = {name: bool(value.strip()) for name, value in values.items()}
    reasons: list[str] = []
    base = urlparse(values["E22_ISOLATED_BASE_URL"])
    db = urlparse(values["E22_DATABASE_URL"])
    if not all(presence.values()):
        reasons.append("AUTHORIZED_ISOLATED_RUNTIME_VALUES_UNAVAILABLE")
    if presence["E22_ISOLATED_BASE_URL"]:
        if base.scheme not in {"http", "https"} or not base.hostname or base.path not in {"", "/"}:
            reasons.append("ISOLATED_BASE_URL_INVALID")
        host = (base.hostname or "").lower()
        if deny_production and (host in PRODUCTION_HOSTS or "prod" in host or "production" in host):
            reasons.append("PRODUCTION_OR_AMBIGUOUS_HOST_REJECTED")
        if host and not any(marker in host for marker in ("localhost", "127.0.0.1", "test", "staging", "sandbox", "isolated", "e22", "ephemeral")):
            reasons.append("HOST_LACKS_NON_PRODUCTION_PROOF")
    if presence["E22_DATABASE_URL"]:
        if db.scheme not in {"postgres", "postgresql"} or not db.hostname or not db.path.strip("/"):
            reasons.append("DATABASE_URL_INVALID")
        target = f"{db.hostname or ''}/{db.path.strip('/')}".lower()
        if deny_production and ("prod" in target or "production" in target or (db.hostname or "").lower() in PRODUCTION_HOSTS):
            reasons.append("PRODUCTION_OR_AMBIGUOUS_DATABASE_REJECTED")
        if not any(marker in target for marker in ("localhost", "127.0.0.1", "test", "staging", "sandbox", "isolated", "e22", "ephemeral")):
            reasons.append("DATABASE_LACKS_NON_PRODUCTION_PROOF")
    hashes = {
        "isolated_base_url_sha256": sha256_bytes(values["E22_ISOLATED_BASE_URL"].encode()) if presence["E22_ISOLATED_BASE_URL"] else None,
        "database_target_sha256": sha256_bytes(values["E22_DATABASE_URL"].encode()) if presence["E22_DATABASE_URL"] else None,
        "admin_token_sha256": sha256_bytes(values["E22_ADMIN_TOKEN"].encode()) if presence["E22_ADMIN_TOKEN"] else None,
    }
    return {"ready": not reasons, "presence": presence, "reasons": sorted(set(reasons)), "hashes": hashes}


def assert_no_secret_values(paths: list[Path]) -> None:
    values = [os.environ.get(name, "") for name in ENV_NAMES]
    values = [v.encode() for v in values if v]
    for path in paths:
        body = path.read_bytes()
        require(not any(v in body for v in values), f"runtime secret reflected in {path}")
