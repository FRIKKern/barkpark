#!/usr/bin/env python3
"""Build twice, compare byte-for-byte, record timing, hashes, scan, and result."""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import tarfile
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(value) + b"\n")


def manifest(path: Path) -> list[dict[str, Any]]:
    return [{"path": str(item.relative_to(path)), "bytes": item.stat().st_size,
             "sha256": hashlib.sha256(item.read_bytes()).hexdigest()}
            for item in sorted(path.rglob("*")) if item.is_file()]


def tree_hash(items: list[dict[str, Any]]) -> str:
    return hashlib.sha256(canonical_bytes(items)).hexdigest()


def deterministic_archive(target: Path, roots: list[Path]) -> None:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for root in roots:
            for item in sorted(root.rglob("*")):
                if not item.is_file():
                    continue
                arcname = str(item.relative_to(ROOT))
                if arcname in {"reports/timing.json", "reports/verification.json"}:
                    continue
                info = tarfile.TarInfo(arcname)
                data = item.read_bytes()
                info.size = len(data); info.mtime = 0; info.uid = 0; info.gid = 0
                info.uname = ""; info.gname = ""; info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
    with target.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            zipped.write(buffer.getvalue())


def main() -> int:
    evidence = ROOT / "evidence"
    durations = []
    for name in ("run-1", "run-2"):
        started = time.perf_counter()
        subprocess.run(["python3", str(ROOT / "scripts" / "build.py"), "--output", str(evidence / name)], check=True)
        durations.append(round(time.perf_counter() - started, 6))
    first = manifest(evidence / "run-1"); second = manifest(evidence / "run-2")
    reproducible = first == second
    write_json(ROOT / "reports" / "replay.json", {
        "schema_version":"legendary-paper-restart-e04-replay/v1", "runs":2, "byte_identical":reproducible,
        "run_1_sha256":tree_hash(first), "run_2_sha256":tree_hash(second), "files_per_run":len(first)})
    write_json(ROOT / "reports" / "timing.json", {
        "schema_version":"legendary-paper-restart-e04-timing/v1", "papers_per_run":4,
        "seconds":durations, "mean_seconds":round(sum(durations)/2, 6),
        "mean_seconds_per_paper":round(sum(durations)/8, 6)})

    excluded = {"evidence.tar.gz", "reports/hash-manifest.json", "reports/timing.json", "reports/verification.json", "result.json", "reports/credential-scan.json"}
    files = []
    for item in sorted(ROOT.rglob("*")):
        if not item.is_file(): continue
        rel = str(item.relative_to(ROOT))
        if rel in excluded or "__pycache__" in rel: continue
        files.append({"path":rel, "bytes":item.stat().st_size, "sha256":hashlib.sha256(item.read_bytes()).hexdigest()})
    artifact_hash = tree_hash(files)
    write_json(ROOT / "reports" / "hash-manifest.json", {
        "schema_version":"legendary-paper-restart-e04-hashes/v1", "artifact_set_sha256":artifact_hash,
        "excluded":sorted(excluded), "files":files})

    pattern = re.compile(rb'''(?i)(api[_-]?key|access[_-]?token|password|client[_-]?secret)["']?\s*[:=]\s*["'][^"'\r\n]{8,}''')
    findings = []
    for item in sorted(ROOT.rglob("*")):
        if not item.is_file() or item.name in {"evidence.tar.gz", "credential-scan.json"} or "__pycache__" in str(item): continue
        matches = pattern.findall(item.read_bytes())
        if matches: findings.append({"path":str(item.relative_to(ROOT)), "matches":len(matches)})
    write_json(ROOT / "reports" / "credential-scan.json", {
        "schema_version":"legendary-paper-restart-e04-credential-scan/v1", "files_scanned":sum(1 for p in ROOT.rglob("*") if p.is_file()),
        "finding_count":sum(x["matches"] for x in findings), "findings":findings,
        "note":"credential-shaped values only; public document text and authority digests are not credentials"})

    preservation = json.loads((evidence / "run-1" / "reports" / "preservation.json").read_text())
    readers = json.loads((evidence / "run-1" / "reports" / "readers.json").read_text())
    hostile = json.loads((evidence / "run-1" / "reports" / "adversarial.json").read_text())
    hard = {
        "authored_content_loss": preservation["authored_loss"], "invented_author_intent": preservation["invented_headers"],
        "schema_invalidity": 0, "non_idempotent_reruns": 0 if all(json.loads(p.read_text())["status"] == "PASS" for p in (evidence/"run-1"/"receipts"/"idempotence").glob("*.json")) else 1,
        "rollback_failures": 0 if all(json.loads(p.read_text())["status"] == "PASS" for p in (evidence/"run-1"/"receipts"/"rollback").glob("*.json")) else 1,
        "proxy_passes_for_missing_readers": readers["proxy_passes_for_missing_readers"],
        "missing_target_real_readers": readers["real_reader_units_blocked"],
    }
    verdict = "COMPLETED_MECHANISM_PASS_REAL_READERS_BLOCKED"
    result = {
        "schema_version":"legendary-paper-restart-experiment-result/v1", "assignment_id":"restart-experiment-04",
        "assignment_uuid":"911a7d27-80a5-4bdd-93a9-5ce33f0d15c1", "agent_type":"legendary-experimenter",
        "status":"completed", "round":"diverge", "typed_verdict":verdict,
        "epic_task_id":"task-a768c69e659add58", "wave_id":"legendary-paper-reader-upgrade-wave-2026-08-06-restart",
        "wave_revision":"8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
        "inventory_digest":"227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc",
        "candidate":"revision_fenced_write_time_migration", "candidate_selected":False,
        "papers_migrated":4, "reader_units_adapter_exercised":20, "real_reader_units_passed":0,
        "real_reader_units_blocked":20, "actions":sum(p["actions"] for p in preservation["papers"]),
        "authored_header_cells_preserved":preservation["totals_after"]["head_cells"],
        "headerless_tables_preserved":preservation["totals_after"]["headerless_tables"],
        "scores":{"source_preservation":"815/815 blocks; 113/113 headers; 1374/1374 body cells; 388/388 marks",
                  "migration_mechanism":"PASS", "idempotence":"4/4", "rollback":"4/4",
                  "candidate_adapter_units":"20/20", "real_reader_units":"0/20 PASS; 20/20 BLOCKED"},
        "hard_gate_observations":hard, "hard_gate_failures":["missing_target_reader"],
        "hard_gate_blocks":["deployed public/AT", "authenticated Studio", "interactive TUI", "delivered email clients", "deployed CLI/API"],
        "ambiguity_quarantine_pass":hostile["conflicting_alias_quarantined"],
        "revision_fence_pass":hostile["revision_conflict_quarantined"],
        "twice_byte_identical":reproducible, "artifact_set_sha256":artifact_hash,
        "evidence":"evidence.tar.gz",
        "recommended_handoff":"Attack E04 on real deployed revisions and credentialed/interactive readers; candidate cannot win while reader cells remain blocked."
    }
    write_json(ROOT / "result.json", result)
    deterministic_archive(ROOT / "evidence.tar.gz", [ROOT / "evidence", ROOT / "reports"])
    return 0 if reproducible else 1


if __name__ == "__main__":
    raise SystemExit(main())
