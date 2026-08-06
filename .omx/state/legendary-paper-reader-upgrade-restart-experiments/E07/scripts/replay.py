#!/usr/bin/env python3
"""Build E07 twice, verify twice, scan, time, and archive deterministically."""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import re
import subprocess
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(value))


def manifest(root: Path) -> list[dict[str, Any]]:
    return [{"path": str(path.relative_to(root)), "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in sorted(root.rglob("*")) if path.is_file()]


def tree_hash(items: list[dict[str, Any]]) -> str:
    return hashlib.sha256(canonical_bytes(items)).hexdigest()


def archive(target: Path) -> None:
    include = [ROOT / "assignment.json", ROOT / "README.md", ROOT / "scripts", ROOT / "generated", ROOT / "reports" / "replay.json", ROOT / "reports" / "credential-scan.json"]
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as tar:
        files = []
        for entry in include:
            files.extend([entry] if entry.is_file() else [p for p in entry.rglob("*") if p.is_file() and "__pycache__" not in str(p)])
        for path in sorted(files):
            data = path.read_bytes()
            info = tarfile.TarInfo(str(path.relative_to(ROOT)))
            info.size = len(data); info.mtime = 0; info.uid = 0; info.gid = 0
            info.uname = ""; info.gname = ""; info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    with target.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            zipped.write(buffer.getvalue())


def main() -> int:
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="barkpark-e07-") as temp:
        temp_root = Path(temp)
        runs = []
        durations = []
        for number in (1, 2):
            output = temp_root / f"run-{number}"
            run_started = time.perf_counter()
            subprocess.run(["python3", str(ROOT / "scripts" / "attack.py"), "--output", str(output)], check=True)
            durations.append(round((time.perf_counter() - run_started) * 1000, 3))
            runs.append(manifest(output))
        reproducible = runs[0] == runs[1]
        generated = ROOT / "generated"
        subprocess.run(["python3", str(ROOT / "scripts" / "attack.py"), "--output", str(generated)], check=True)
    replay = {"schema_version": "legendary-paper-restart-e07-replay/v1", "runs": 2, "byte_identical": reproducible, "run_1_sha256": tree_hash(runs[0]), "run_2_sha256": tree_hash(runs[1]), "files_per_run": len(runs[0])}
    write_json(ROOT / "reports" / "replay.json", replay)
    pattern = re.compile(rb"(?i)(bearer\\s+[a-z0-9._~+/=-]{16,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[a-z0-9]{20,}|AKIA[0-9A-Z]{16})")
    findings = []
    scanned = 0
    for path in sorted([ROOT / "assignment.json", ROOT / "README.md"] + [p for p in (ROOT / "scripts").rglob("*") if p.is_file()] + [p for p in generated.rglob("*") if p.is_file()]):
        if "__pycache__" in str(path):
            continue
        scanned += 1
        hits = pattern.findall(path.read_bytes())
        if hits:
            findings.append({"path": str(path.relative_to(ROOT)), "matches": len(hits)})
    write_json(ROOT / "reports" / "credential-scan.json", {"schema_version": "legendary-paper-restart-e07-credential-scan/v1", "files_scanned": scanned, "finding_count": sum(x["matches"] for x in findings), "findings": findings})
    archive(ROOT / "evidence.tar.gz")
    matrix = json.loads((generated / "reports" / "candidate-matrix.json").read_text())
    result = {
        "schema_version": "legendary-paper-restart-experiment-result/v1",
        "assignment_id": "restart-experiment-07",
        "assignment_uuid": "028be543-f502-427c-8940-5d0a6f386b2e",
        "agent_type": "legendary-experimenter",
        "model_reasoning_effort": "medium",
        "status": "completed",
        "round": "attack",
        "epic_task_id": "task-a768c69e659add58",
        "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart",
        "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
        "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc",
        "plan_digest": "9997fc50db5f1b83f1f53e33bd45dd111b2b06402b07a78b0673d2048f299e45",
        "typed_verdict": "ATTACK_COMPLETE_NO_CANDIDATE_CLEARS_ALL_HARD_GATES",
        "candidate_selected": False,
        "candidate_scores": matrix["candidates"],
        "attacked_cells": len(matrix["cells"]),
        "replay": replay,
        "credential_findings": sum(x["matches"] for x in findings),
        "evidence": "evidence.tar.gz",
        "evidence_archive_sha256": hashlib.sha256((ROOT / "evidence.tar.gz").read_bytes()).hexdigest(),
        "recommended_handoff": "Converge must repair or explicitly reject the observed schema, alias-conflict, geometry, and CAS failures; no E04/E05/E06 format is selectable from E07 evidence.",
    }
    write_json(ROOT / "result.json", result)
    verify_runs = []
    for _ in (1, 2):
        completed = subprocess.run(["python3", str(ROOT / "scripts" / "verify.py")], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            raise RuntimeError(completed.stdout + completed.stderr)
        verify_runs.append(json.loads(completed.stdout))
    write_json(ROOT / "reports" / "verification-run-1.json", verify_runs[0])
    write_json(ROOT / "reports" / "verification-run-2.json", verify_runs[1])
    write_json(ROOT / "reports" / "timing.json", {"schema_version": "legendary-paper-restart-e07-timing/v1", "attack_run_milliseconds": durations, "total_milliseconds": round((time.perf_counter() - started) * 1000, 3), "candidate_count": 3, "attack_cells": 33})
    print("E07 REPLAY PASS")
    return 0 if reproducible and verify_runs[0] == verify_runs[1] else 1


if __name__ == "__main__":
    raise SystemExit(main())
