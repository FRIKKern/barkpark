#!/usr/bin/env python3
"""Replay E12 twice, scan credentials, archive deterministic evidence, and verify twice."""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import re
import subprocess
import tarfile
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parents[1]


def canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value))


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def manifest(root: Path) -> list[dict[str, Any]]:
    return [{"path": path.relative_to(root).as_posix(), "bytes": len(path.read_bytes()), "sha256": sha(path.read_bytes())} for path in sorted(root.rglob("*")) if path.is_file()]


EXCLUDED = {"evidence.tar.gz", "result.json", "reports/credential-scan.json", "reports/hash-manifest.json", "reports/timing.json", "reports/verification-run-1.json", "reports/verification-run-2.json"}


def archive() -> None:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as handle:
        for path in sorted(item for item in HERE.rglob("*") if item.is_file()):
            relative = path.relative_to(HERE).as_posix()
            if relative in EXCLUDED or "__pycache__" in relative:
                continue
            data = path.read_bytes()
            info = tarfile.TarInfo(relative)
            info.size = len(data)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o644
            handle.addfile(info, io.BytesIO(data))
    with (HERE / "evidence.tar.gz").open("wb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as zipped:
            zipped.write(buffer.getvalue())


def main() -> int:
    durations = []
    for run in ("run-1", "run-2"):
        started = time.monotonic()
        subprocess.run(["python3", str(HERE / "scripts" / "converge.py"), "--output", str(HERE / "evidence" / run)], check=True)
        subprocess.run(["python3", str(HERE / "scripts" / "check_contract.py"), "--matrix", str(HERE / "evidence" / run / "terminal-platform-matrix.json"), "--output", str(HERE / "evidence" / run / "executable-contract-verdict.json")], check=True, stdout=subprocess.DEVNULL)
        durations.append(round(time.monotonic() - started, 6))
    first = manifest(HERE / "evidence" / "run-1")
    second = manifest(HERE / "evidence" / "run-2")
    replay = {"schema_version": "legendary-restart-e12-replay/v1", "runs": 2, "byte_identical": first == second, "files_per_run": len(first), "run_1_manifest_sha256": sha(canonical(first)), "run_2_manifest_sha256": sha(canonical(second))}
    write(HERE / "reports" / "replay.json", replay)
    write(HERE / "reports" / "timing.json", {"schema_version": "legendary-restart-e12-timing/v1", "run_seconds": durations, "mean_seconds": round(sum(durations) / 2, 6), "candidates_per_run": 3, "papers_per_run": 4, "matrix_cells_per_run": sum(json.loads((HERE / "evidence" / "run-1" / "terminal-platform-matrix.json").read_text())["status_counts"].values())})

    patterns = {"private_key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"), "github_token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"), "openai_key": re.compile(rb"sk-[A-Za-z0-9]{32,}"), "bearer": re.compile(rb"Authorization:\s*Bearer\s+[A-Za-z0-9._~-]{20,}", re.I)}
    hits = []
    scanned = 0
    for path in sorted(item for item in HERE.rglob("*") if item.is_file()):
        relative = path.relative_to(HERE).as_posix()
        if relative in EXCLUDED or "__pycache__" in relative:
            continue
        data = path.read_bytes()
        scanned += 1
        for name, pattern in patterns.items():
            if pattern.search(data):
                hits.append({"path": relative, "pattern": name})
    write(HERE / "reports" / "credential-scan.json", {"schema_version": "legendary-restart-e12-credential-scan/v1", "files_scanned": scanned, "hit_count": len(hits), "hits": hits})

    files = []
    for path in sorted(item for item in HERE.rglob("*") if item.is_file()):
        relative = path.relative_to(HERE).as_posix()
        if relative in EXCLUDED or "__pycache__" in relative:
            continue
        data = path.read_bytes()
        files.append({"path": relative, "bytes": len(data), "sha256": sha(data)})
    artifact_hash = sha(canonical(files))
    write(HERE / "reports" / "hash-manifest.json", {"schema_version": "legendary-restart-e12-hashes/v1", "artifact_set_sha256": artifact_hash, "excluded": sorted(EXCLUDED), "files": files})
    archive()

    evaluation = json.loads((HERE / "evidence" / "run-1" / "contract-evaluation.json").read_text())
    matrix = json.loads((HERE / "evidence" / "run-1" / "terminal-platform-matrix.json").read_text())
    result = {"schema_version": "legendary-paper-restart-experiment-result/v1", "assignment_id": "restart-experiment-12", "assignment_uuid": "39827795-e05e-4f99-944c-05fd1efdda43", "agent_type": "legendary-experimenter", "model_reasoning_effort": "medium", "round": "converge", "status": "completed", "verdict": "CONVERGE_NO_WINNER_REPLACEMENT_WAVE_REQUIRED", "candidate_selected": False, "pilot_authorized": False, "eligible_candidates": [], "authority": {"epic_id": "task-a768c69e659add58", "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart", "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737", "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc", "plan_digest": "9997fc50db5f1b83f1f53e33bd45dd111b2b06402b07a78b0673d2048f299e45"}, "scores": matrix["status_counts"], "candidate_scores": matrix["per_candidate"], "hard_failures": ["terminal_control_leaks:E04", "terminal_control_leaks:E05", "terminal_control_leaks:E06", "bounded_rendering:E06:18_of_20", "request_id:E04", "request_id:E06", "identity_domains:E04", "identity_domains:E05"], "blocks": ["E04 renderer coverage", "all candidate interaction/state/history/Related/recovery cells", "all candidate typed 401/404/405/406/422/500/timeout cells", "E04/E05 conditional ETag handlers", "capabilities/OpenAPI/help/pagination for every candidate", "complete request-ID evidence including error paths"], "replacement_wave_contract": "contract/replacement-wave-contract.json", "replacement_wave_required": True, "replay": replay, "timing": json.loads((HERE / "reports" / "timing.json").read_text()), "credential_scan": json.loads((HERE / "reports" / "credential-scan.json").read_text()), "artifact_set_sha256": artifact_hash, "evidence_archive_sha256": sha((HERE / "evidence.tar.gz").read_bytes()), "observations": evaluation["observations"], "preference": [], "recommended_handoff": "Open a new immutable replacement wave. Implement every frozen contract surface in isolation, rerun Attack and Converge, and do not authorize Pilot until one candidate has PASS in every required cell."}
    write(HERE / "result.json", result)
    subprocess.run(["python3", str(HERE / "scripts" / "verify.py"), "--output", str(HERE / "reports" / "verification-run-1.json")], check=True)
    subprocess.run(["python3", str(HERE / "scripts" / "verify.py"), "--output", str(HERE / "reports" / "verification-run-2.json")], check=True)
    return 0 if replay["byte_identical"] and not hits and (HERE / "reports" / "verification-run-1.json").read_bytes() == (HERE / "reports" / "verification-run-2.json").read_bytes() else 1


if __name__ == "__main__":
    raise SystemExit(main())
