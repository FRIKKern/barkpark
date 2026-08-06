#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import tempfile
import time
from pathlib import Path

from candidate import HERE, build, canonical_bytes


def manifest(root: Path) -> dict[str, dict[str, int | str]]:
    result = {}
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        data = path.read_bytes()
        result[path.relative_to(root).as_posix()] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    return result


started = time.monotonic()
with tempfile.TemporaryDirectory(prefix="barkpark-e06-replay-") as temp:
    temp_root = Path(temp)
    run1 = temp_root / "run1"
    run2 = temp_root / "run2"
    t1 = time.monotonic()
    build(run1)
    d1 = time.monotonic() - t1
    t2 = time.monotonic()
    build(run2)
    d2 = time.monotonic() - t2
    first = manifest(run1)
    second = manifest(run2)
    current = manifest(HERE / "generated")
    report = {
        "schema_version": "legendary-paper-restart-e06-replay/v1",
        "runs": 2,
        "byte_identical": first == second,
        "current_matches_replay": current == first,
        "file_count": len(first),
        "run_1_seconds": round(d1, 6),
        "run_2_seconds": round(d2, 6),
        "wall_seconds": round(time.monotonic() - started, 6),
        "manifest_sha256": hashlib.sha256(canonical_bytes(first)).hexdigest(),
        "differences": sorted(set(first) ^ set(second)) if first != second else [],
    }
    if not report["byte_identical"] or not report["current_matches_replay"]:
        raise SystemExit(json.dumps(report, sort_keys=True))
(HERE / "reports").mkdir(parents=True, exist_ok=True)
(HERE / "reports" / "replay.json").write_bytes(canonical_bytes(report))
print(json.dumps(report, sort_keys=True, separators=(",", ":")))
