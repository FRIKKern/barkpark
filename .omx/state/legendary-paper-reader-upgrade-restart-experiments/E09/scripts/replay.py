#!/usr/bin/env python3
"""Run E09 twice, compare byte evidence, scan, archive, and emit the result."""

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


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def manifest(root: Path) -> list[dict[str, Any]]:
    return [{"path": path.relative_to(root).as_posix(), "bytes": len(path.read_bytes()), "sha256": sha256(path.read_bytes())} for path in sorted(root.rglob("*")) if path.is_file()]


def archive(target: Path) -> None:
    excluded = {"evidence.tar.gz", "result.json", "reports/timing.json", "reports/hash-manifest.json", "reports/credential-scan.json", "reports/verification.json"}
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as handle:
        for path in sorted(item for item in HERE.rglob("*") if item.is_file()):
            relative = path.relative_to(HERE).as_posix()
            if relative in excluded or "__pycache__" in relative:
                continue
            data = path.read_bytes()
            info = tarfile.TarInfo(relative)
            info.size = len(data)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o644
            handle.addfile(info, io.BytesIO(data))
    with target.open("wb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as zipped:
            zipped.write(buffer.getvalue())


def main() -> int:
    durations = []
    for run in ("run-1", "run-2"):
        started = time.monotonic()
        subprocess.run(["python3", str(HERE / "scripts" / "attack.py"), "--output", str(HERE / "evidence" / run)], check=True)
        durations.append(round(time.monotonic() - started, 6))
    first = manifest(HERE / "evidence" / "run-1")
    second = manifest(HERE / "evidence" / "run-2")
    replay = {"schema_version": "legendary-restart-e09-replay/v1", "runs": 2, "byte_identical": first == second, "run_1_manifest_sha256": sha256(canonical(first)), "run_2_manifest_sha256": sha256(canonical(second)), "files_per_run": len(first)}
    write(HERE / "reports" / "replay.json", replay)
    write(HERE / "reports" / "timing.json", {"schema_version": "legendary-restart-e09-timing/v1", "run_seconds": durations, "mean_seconds": round(sum(durations) / 2, 6), "papers_per_run": 4, "candidates_per_run": 3})

    credential_patterns = {
        "private_key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        "github_token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
        "openai_key": re.compile(rb"sk-[A-Za-z0-9]{32,}"),
        "bearer": re.compile(rb"Authorization:\s*Bearer\s+[A-Za-z0-9._~-]{20,}", re.I),
    }
    hits = []
    scanned = 0
    for path in sorted(item for item in HERE.rglob("*") if item.is_file()):
        relative = path.relative_to(HERE).as_posix()
        if relative in {"evidence.tar.gz", "reports/credential-scan.json"} or "__pycache__" in relative:
            continue
        data = path.read_bytes()
        scanned += 1
        for name, pattern in credential_patterns.items():
            if pattern.search(data):
                hits.append({"path": relative, "pattern": name})
    write(HERE / "reports" / "credential-scan.json", {"schema_version": "legendary-restart-e09-credential-scan/v1", "files_scanned": scanned, "hit_count": len(hits), "hits": hits})

    excluded = {"evidence.tar.gz", "result.json", "reports/hash-manifest.json", "reports/timing.json", "reports/credential-scan.json", "reports/verification.json"}
    files = []
    for path in sorted(item for item in HERE.rglob("*") if item.is_file()):
        relative = path.relative_to(HERE).as_posix()
        if relative in excluded or "__pycache__" in relative:
            continue
        data = path.read_bytes()
        files.append({"path": relative, "bytes": len(data), "sha256": sha256(data)})
    artifact_hash = sha256(canonical(files))
    write(HERE / "reports" / "hash-manifest.json", {"schema_version": "legendary-restart-e09-hashes/v1", "artifact_set_sha256": artifact_hash, "excluded": sorted(excluded), "files": files})
    archive(HERE / "evidence.tar.gz")

    summary = json.loads((HERE / "evidence" / "run-1" / "summary.json").read_text())
    widths = json.loads((HERE / "evidence" / "run-1" / "terminal-widths.json").read_text())["rows"]
    controls = json.loads((HERE / "evidence" / "run-1" / "control-bytes.json").read_text())["rows"]
    result = {
        "schema_version": "legendary-paper-restart-experiment-result/v1",
        "assignment_id": "restart-experiment-09",
        "assignment_uuid": "65cda1a4-64a1-45bd-a27d-1256e460210a",
        "agent_type": "legendary-experimenter",
        "model_reasoning_effort": "medium",
        "round": "attack",
        "status": "completed",
        "verdict": "ATTACK_FAIL_WITH_TYPED_BLOCKS",
        "candidate_selected": False,
        "authority": {"epic_id": "task-a768c69e659add58", "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart", "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737", "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc", "plan_digest": "9997fc50db5f1b83f1f53e33bd45dd111b2b06402b07a78b0673d2048f299e45"},
        "scores": {"width_cells_pass": sum(row["status"] == "PASS" for row in widths), "width_cells_fail": sum(row["status"] == "FAIL" for row in widths), "width_cells_blocked": sum(row["status"].startswith("BLOCKED") for row in widths), "width_cells_total": len(widths), "control_byte_failures": sum(row["status"] == "FAIL" for row in controls), "status_counts": summary["status_counts"]},
        "hard_failures": ["terminal_control_leaks:E04", "terminal_control_leaks:E05", "terminal_control_leaks:E06", "bounded_rendering:E06:18_of_20_cells", "missing_request_id:E04", "missing_request_id:E06", "identity_domains_incomplete:E04"],
        "blocks": ["all interactive mouse/focus/scroll/click/Enter and state/history/Related/recovery cells", "capabilities/OpenAPI/help/pagination agreement for every candidate", "safe typed 401/404/405/406/422/500/timeout and exit-code simulation for every candidate", "E04 all-width renderer", "E04/E05 runnable conditional handler"],
        "replay": replay,
        "timing": json.loads((HERE / "reports" / "timing.json").read_text()),
        "credential_scan": json.loads((HERE / "reports" / "credential-scan.json").read_text()),
        "artifact_set_sha256": artifact_hash,
        "evidence_archive_sha256": sha256((HERE / "evidence.tar.gz").read_bytes()),
        "observations": summary["observations"],
        "preference": [],
        "recommended_handoff": "Do not converge or select any candidate from E09: repair terminal sanitization and supply isolated interactive plus typed-error simulators, then rerun Attack in a new authorized assignment."
    }
    write(HERE / "result.json", result)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0 if replay["byte_identical"] and not hits else 1


if __name__ == "__main__":
    raise SystemExit(main())
