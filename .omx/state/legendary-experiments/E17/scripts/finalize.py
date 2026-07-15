#!/usr/bin/env python3
"""Seal hashes, isolated replay timing, and the truthful E17 verdict."""

from __future__ import annotations

import json
import statistics
import tempfile
import time
from pathlib import Path

from build import build
from common import ROOT, physical_hash, write_json


def main() -> None:
    observations: list[float] = []
    with tempfile.TemporaryDirectory(prefix="e17-finalize-") as tmp:
        for index in range(3):
            started = time.perf_counter()
            build(Path(tmp) / f"run-{index}")
            observations.append(time.perf_counter() - started)
    write_json(ROOT / "timing-replay.json", {
        "schema_version": "legendary-e17-replay-timing/v1",
        "clean_replays": 3,
        "seconds": [round(value, 6) for value in observations],
        "median_seconds": round(statistics.median(observations), 6),
        "excluded_from_deterministic_hashes": True,
    })

    hash_paths = [
        ROOT / "README.md",
        ROOT / "attempt-index.json",
        ROOT / "scripts" / "common.py",
        ROOT / "scripts" / "probe.py",
        ROOT / "scripts" / "build.py",
        ROOT / "scripts" / "finalize.py",
        ROOT / "scripts" / "verify.py",
        ROOT / "scripts" / "replay.sh",
        ROOT / "output" / "cells.jsonl",
        ROOT / "output" / "reconciliation.json",
        ROOT / "output" / "hard-gates.json",
    ]
    hash_paths.extend(sorted((ROOT / "attempts" / "raw").glob("*/*.json")))
    hashes = {str(path.relative_to(ROOT)): physical_hash(path) for path in hash_paths}
    write_json(ROOT / "output" / "hashes.json", {
        "schema_version": "legendary-e17-artifact-hashes/v1",
        "file_count": len(hashes),
        "files": hashes,
    })
    write_json(ROOT / "result.json", {
        "schema_version": "legendary-e17-result/v1",
        "assignment_id": "E17",
        "candidate_id": "candidate-lossless-semantic-tree",
        "assignment_source": "E11/next-three-assignments.json",
        "counts": {
            "fixtures": 36,
            "surfaces": 5,
            "cells": 180,
            "hashed_attempt_artifacts": 180,
            "accepted_candidate_specific_captures": 0,
            "blocked_cells": 180,
            "silent_proxy_promotions": 0,
        },
        "capability_blocks": [
            "Authenticated Studio redirected to login; the API bearer token did not establish a browser session and E16 was not deployed.",
            "Public reader responses lacked a deployed E16 provenance marker, so URL-reflected pages were not accepted as captures.",
            "The real TUI failed during schema loading before candidate selection.",
            "Mail.app was present, but candidate email endpoints returned 404; no message was imported and no proxy was substituted.",
            "bp paper view reported the candidate-shaped slugs absent.",
        ],
        "threshold_outcomes": json.loads((ROOT / "output" / "hard-gates.json").read_text())["outcomes"],
        "evidence": {
            "attempt_index": "attempt-index.json",
            "cells": "output/cells.jsonl",
            "reconciliation": "output/reconciliation.json",
            "hashes": "output/hashes.json",
            "validation_command": ".omx/state/legendary-experiments/E17/scripts/replay.sh",
            "expected_output": "E17 REPLAY PASS verdict=FAIL/REWORK captures=0 attempts=180",
        },
        "verdict": {
            "quality": "FAIL",
            "action": "REWORK",
            "winner_selected": False,
            "pilot_authorized": False,
            "real_surface_gate_passed": False,
        },
    })
    print(f"E17 FINALIZE PASS hashes={len(hashes)} verdict=FAIL/REWORK")


if __name__ == "__main__":
    main()
