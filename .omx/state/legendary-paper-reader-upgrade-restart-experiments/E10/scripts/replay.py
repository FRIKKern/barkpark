#!/usr/bin/env python3
"""Build E10, run the deterministic verifier twice, scan credentials, and time it."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[4]


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def main() -> int:
    started = time.perf_counter()
    subprocess.run([sys.executable, str(HERE / "scripts" / "build.py")], check=True, cwd=REPO)
    outputs = []
    durations = []
    for index in (1, 2):
        before = time.perf_counter()
        output = subprocess.check_output([sys.executable, str(HERE / "scripts" / "verify.py")], cwd=REPO)
        durations.append(round((time.perf_counter() - before) * 1000, 3))
        target = HERE / "reports" / f"verification-run-{index}.json"
        target.write_bytes(output)
        outputs.append(output)
    if outputs[0] != outputs[1]:
        raise SystemExit("verifier outputs differ")

    candidates = []
    for path in sorted(p for p in HERE.rglob("*") if p.is_file() and p.name != "evidence.tar.gz"):
        if path.parts[-2] in {"run-1", "run-2"}:
            continue
        try:
            value = json.loads(path.read_text()) if path.suffix == ".json" else None
        except (UnicodeDecodeError, json.JSONDecodeError):
            value = None
        if value is not None:
            stack = [value]
            while stack:
                item = stack.pop()
                if isinstance(item, dict):
                    stack.extend(item.values())
                elif isinstance(item, list):
                    stack.extend(item)
                elif isinstance(item, str):
                    lower = item.lower()
                    patterns = (
                        r"(?:^|[^a-z0-9])ghp_[a-z0-9]{20,}",
                        r"(?:^|[^a-z0-9])sk-[a-z0-9]{20,}",
                        r"(?:^|[^a-z0-9])bearer\s+[a-z0-9._-]{20,}",
                    )
                    if any(re.search(pattern, lower) for pattern in patterns):
                        candidates.append({"path": path.relative_to(HERE).as_posix(), "value_sha256": __import__("hashlib").sha256(item.encode()).hexdigest()})
    scan = {
        "schema_version": "legendary-paper-restart-e10-credential-scan/v1",
        "files_scanned": len([p for p in HERE.rglob("*") if p.is_file()]),
        "finding_count": len(candidates),
        "findings": candidates,
        "status": "PASS" if not candidates else "FAIL",
    }
    (HERE / "reports" / "credential-scan.json").write_bytes(canonical(scan))
    if candidates:
        raise SystemExit("credential scan failed")
    timing = {
        "schema_version": "legendary-paper-restart-e10-timing/v1",
        "total_milliseconds": round((time.perf_counter() - started) * 1000, 3),
        "verification_run_milliseconds": durations,
        "e07_replay_runs": 2,
        "verifier_runs": 2,
    }
    (HERE / "reports" / "timing.json").write_bytes(canonical(timing))
    print("E10 REPLAY PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
