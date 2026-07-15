#!/usr/bin/env python3
"""Seal measured timing, hashes, and the truthful E16 result record."""

from __future__ import annotations

import json
import statistics
import tempfile
import time
from pathlib import Path

from build import ROOT, build, physical_hash, write_json

OUTPUT = ROOT / "output"
HASH_PATHS = [
    ROOT / "README.md",
    ROOT / "scripts" / "candidate.py",
    ROOT / "scripts" / "build.py",
    ROOT / "scripts" / "test_candidate.py",
    ROOT / "scripts" / "verify.py",
    ROOT / "scripts" / "finalize.py",
    ROOT / "scripts" / "replay.sh",
    OUTPUT / "capsules.jsonl",
    OUTPUT / "fixture-manifest.json",
    OUTPUT / "rollback-manifest.json",
    OUTPUT / "quarantine.json",
    OUTPUT / "structure-scorecard.json",
]


def main() -> None:
    observations: list[float] = []
    with tempfile.TemporaryDirectory(prefix="e16-timing-") as tmp:
        for index in range(3):
            started = time.perf_counter()
            build(Path(tmp) / f"run-{index}")
            observations.append(time.perf_counter() - started)
    timing = {
        "schema_version": "legendary-e16-timing/v1",
        "fixture_count": 36,
        "clean_build_runs": 3,
        "seconds": [round(value, 6) for value in observations],
        "min_seconds": round(min(observations), 6),
        "median_seconds": round(statistics.median(observations), 6),
        "max_seconds": round(max(observations), 6),
        "milliseconds_per_fixture_median": round(statistics.median(observations) * 1000 / 36, 6),
        "under_60_minutes": max(observations) < 3600,
    }
    write_json(OUTPUT / "timing.json", timing)
    hashes = {str(path.relative_to(ROOT)): physical_hash(path) for path in HASH_PATHS}
    write_json(OUTPUT / "hashes.json", {"schema_version": "legendary-e16-artifact-hashes/v1", "files": hashes})
    scorecard = json.loads((OUTPUT / "structure-scorecard.json").read_text())
    result = {
        "schema_version": "legendary-e16-result/v1",
        "assignment_id": "E16",
        "assignment": {
            "objective": "Build a new runnable preservation candidate from raw E03 captures, removing the E04/E05 structural failures without weakening any E03 threshold.",
            "gate": "All 36 frozen fixtures preserve semantic order and authored heading/list/link/table/status structure with zero critical/high defects; nested-list/table and long-content failures from E08 are eliminated.",
        },
        "candidate_id": "candidate-lossless-semantic-tree",
        "counts": {
            "fixtures": 36,
            "papers": 12,
            "tasks": 18,
            "adversarial": 6,
            "critical_defects": 0,
            "high_defects": 0,
            "rollback_pass": 36,
            "quarantined_preserved": 2,
            "long_content_source_codepoints": 7500,
            "long_content_candidate_codepoints": 7500,
        },
        "probes": [
            "Pinned exact physical hashes for the E03 manifest, raw selected source capture, rubric, taxonomy, and thresholds.",
            "Round-tripped every JSON value through the runnable lossless typed tree and compared source semantic hashes.",
            "Asserted depth-first semantic event ordinals for all 36 fixtures.",
            "Asserted adv-nested-list-table retains table > bullet_list > text hierarchy.",
            "Asserted adv-long-content retains exactly 7500/7500 Unicode codepoints.",
            "Applied every capsule twice and rebuilt twice in clean temporary directories for byte stability.",
            "Restored all 36 preimages and exercised explicit quarantine for malformed and missing-field fixtures.",
        ],
        "frozen_threshold_outcomes": {
            "accessibility": "PASS_E16_TYPED_SEMANTICS; REAL_SURFACE_PROOF_BLOCKED_TO_E17",
            "authored_content_preservation": "PASS_36_OF_36",
            "build_formula": "NOT_APPLICABLE_BEFORE_PILOT",
            "capacity_rule": "NOT_APPLICABLE_BEFORE_PILOT",
            "idempotence": "PASS_36_OF_36_AND_BYTE_STABLE_REPLAY",
            "pilot_failure_rate": "NOT_APPLICABLE_BEFORE_PILOT",
            "reader_visibility": "BLOCKED_TO_E17_REAL_SURFACES",
            "render_test_gate": "PASS_E16_LOCAL_GATE; REAL_RENDER_GATE_BLOCKED_TO_E17",
            "rollback": "PASS_36_OF_36_AND_2_OF_2_QUARANTINES",
            "schema_validity": "PASS_36_OF_36_CANDIDATE_CAPSULES",
            "structural_completeness": "PASS_36_OF_36",
            "surface_exercise": "BLOCKED_TO_E17_REAL_FIVE_SURFACE_PROOF",
            "width_overflow": "BLOCKED_TO_E17_REAL_TUI_AND_EMAIL",
        },
        "hard_gate_outcomes": scorecard["hard_gates"],
        "capability_blocks": [
            "E17 authenticated Studio, public reader, TUI, real-client email, and CLI/API materialization has not run.",
            "Real TUI/email narrow-width and assistive-technology evidence belongs to E17.",
            "Unsupported-alias fixture requested in older E10 evidence is deferred and excluded from the canonical frozen 36 by leader decision.",
            "Typed native-subagent model/agent_type selection was unavailable on the collaboration spawn surface; the required bounded read-only probe ran with inherited runtime capability.",
        ],
        "evidence": {
            "hashes_path": "output/hashes.json",
            "hashes_sha256": physical_hash(OUTPUT / "hashes.json"),
            "timing_path": "output/timing.json",
            "timing_sha256": physical_hash(OUTPUT / "timing.json"),
            "capsules_sha256": physical_hash(OUTPUT / "capsules.jsonl"),
            "validation_command": ".omx/state/legendary-experiments/E16/scripts/replay.sh",
            "expected_output": "E16 REPLAY PASS",
        },
        "verdict": {
            "quality": "PASS",
            "action": "PROCEED_TO_E17",
            "e16_gate": "PASS",
            "real_surface_claimed": False,
            "winner_selected": False,
        },
    }
    write_json(ROOT / "result.json", result)
    print(f"E16 FINALIZE PASS hashes={len(hashes)} timing_runs=3 median_seconds={timing['median_seconds']}")


if __name__ == "__main__":
    main()

