#!/usr/bin/env python3
"""Verify E08 determinism, hashes, counts, and honest hard-gate verdicts."""

import hashlib
import importlib.util
import json
from pathlib import Path

E08 = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("e08_attack", E08 / "scripts/attack.py")
attack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(attack)


def load(name):
    return json.loads((E08 / name).read_text())


def canonical(value):
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def sha(name):
    return hashlib.sha256((E08 / name).read_bytes()).hexdigest()


expected = attack.build_documents()
for name, value in expected.items():
    assert (E08 / name).read_text() == canonical(value), f"non-deterministic or stale {name}"

result = load("result.json")
for name, digest in result["artifact_hashes"].items():
    assert sha(name) == digest, f"hash mismatch: {name}"

matrix = load("attack-matrix.json")["rows"]
cards = load("candidate-scorecards.json")["candidates"]
assert len(cards) == 3 and {c["source_assignment"] for c in cards} == {"E04", "E05", "E06"}
assert all(c["verdict"] == "REJECT" for c in cards)
assert result["counts"]["probes"] == len(matrix)
assert result["counts"]["rejected_candidates"] == 3
assert any(r["candidate_id"] == "candidate-canonical-native" and r["axis"] == "heading and list hierarchy" and r["status"] == "FAIL" for r in matrix)
assert any(r["candidate_id"] == "candidate-preservation-envelope" and r["axis"] == "heading and list hierarchy" and r["status"] == "FAIL" for r in matrix)
assert any(r["candidate_id"] == "candidate-cohort-rails" and r["axis"] == "fixture coverage" and r["status"] == "FAIL" for r in matrix)
assert result["verdict"]["action"] == "REWORK"
assert "authenticated Studio content proof unavailable" in result["capability_blocks"]
print("E08 VERIFY PASS")
