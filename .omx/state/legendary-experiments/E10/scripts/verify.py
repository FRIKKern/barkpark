#!/usr/bin/env python3
"""Verify E10 hashes, deterministic replay, counts, and fail-closed gate."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS = ROOT.parent


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    started = time.monotonic()
    result = load(ROOT / "result.json")
    provenance = load(ROOT / "candidate-provenance.json")
    outcomes = load(ROOT / "threshold-outcomes.json")
    next_three = load(ROOT / "next-complete-three.json")
    decisions = load(ROOT / "rejected-candidate-decision-record.json")

    require(result["assignment_id"] == "E10", "wrong assignment")
    require(result["verdict"]["winner_selected"] is False, "winner invented")
    require(result["verdict"]["action"] == "REWORK", "must require rework")
    require(result["counts"]["winners"] == 0, "winner count must be zero")
    require(result["counts"]["frozen_fixtures"] == 36, "fixture count drift")
    require(result["counts"]["papers"] == 12, "paper count drift")
    require(result["counts"]["tasks"] == 18, "task count drift")
    require(result["counts"]["adversarial"] == 6, "adversarial count drift")
    require(len(outcomes["outcomes"]) == 13, "frozen threshold count drift")
    require(outcomes["winner_gate"] == "FAIL", "winner gate must fail")
    require(outcomes["summary"]["blocked_or_failed"] > 0, "hard failures missing")
    require(next_three["assignment_count"] == 3, "next round must contain three assignments")
    require(len(next_three["assignments"]) == 3, "next round assignment list drift")
    require(decisions["winner_selected"] is False, "decision record invented winner")
    require(decisions["strongest_candidate"] == "E05", "strongest provenance drift")
    require(decisions["candidates"]["E04"]["e10_decision"] == "REJECTED", "E04 decision drift")
    require(decisions["candidates"]["E05"]["e10_decision"] == "BLOCKED_REWORK", "E05 decision drift")
    require(decisions["candidates"]["E06"]["e10_decision"] == "REJECTED", "E06 decision drift")

    require(digest(ROOT / "frozen/candidate-rubric.json") == digest(EXPERIMENTS / "E03/candidate-rubric.json"), "rubric weakened or changed")
    require(digest(ROOT / "frozen/thresholds.json") == digest(EXPERIMENTS / "E03/thresholds.json"), "thresholds weakened or changed")
    require(provenance["candidate"]["content_sha256"] == load(EXPERIMENTS / "E05/result.json")["candidate_semantic_sha256"], "candidate semantic hash drift")
    require(provenance["candidate"]["definition_sha256"] == digest(EXPERIMENTS / "E05/candidate.json"), "candidate definition hash drift")
    require(provenance["candidate"]["runnable_output_sha256"] == digest(EXPERIMENTS / "E05/outputs/envelopes.jsonl"), "candidate output hash drift")
    for record in provenance["source_evidence"].values():
        require(digest((ROOT / record["path"]).resolve()) == record["sha256"], f"source evidence drift: {record['path']}")
    for name, expected in result["artifact_hashes"].items():
        require(digest(ROOT / name) == expected, f"artifact hash drift: {name}")

    with tempfile.TemporaryDirectory(prefix="e10-replay-") as temp:
        replay = Path(temp)
        built = subprocess.run(
            [sys.executable, str(ROOT / "scripts/build.py"), "--output", str(replay)],
            check=True,
            capture_output=True,
            text=True,
        )
        require("E10 BUILD PASS" in built.stdout, "replay builder marker missing")
        for name in [*result["artifact_hashes"], "result.json"]:
            require((ROOT / name).read_bytes() == (replay / name).read_bytes(), f"non-deterministic replay: {name}")

    blocked = subprocess.run(
        [sys.executable, str(ROOT / "scripts/builder_gate.py")],
        capture_output=True,
        text=True,
    )
    require(blocked.returncode == 42, f"builder gate did not fail closed: {blocked.returncode}")
    require("E10 BUILDER GATE BLOCKED" in blocked.stdout, "builder block marker missing")
    expected = subprocess.run(
        [sys.executable, str(ROOT / "scripts/builder_gate.py"), "--expect-blocked"],
        check=True,
        capture_output=True,
        text=True,
    )
    require("E10 EXPECTED BLOCK CONFIRMED" in expected.stdout, "expected-block marker missing")
    print(f"E10 VERIFY PASS elapsed_seconds={time.monotonic() - started:.6f}")


if __name__ == "__main__":
    main()
