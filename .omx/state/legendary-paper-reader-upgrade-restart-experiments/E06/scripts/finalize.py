#!/usr/bin/env python3
from __future__ import annotations

import gzip
import hashlib
import io
import json
import tarfile
from pathlib import Path

from candidate import HERE, canonical_bytes


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


archive_path = HERE / "evidence.tar.gz"
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w") as archive:
    for path in sorted(p for p in (HERE / "generated").rglob("*") if p.is_file()):
        data = path.read_bytes()
        info = tarfile.TarInfo(path.relative_to(HERE).as_posix())
        info.size = len(data)
        info.mtime = 0
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(data))
with archive_path.open("wb") as raw_handle:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw_handle, mtime=0) as zipped:
        zipped.write(buffer.getvalue())

excluded_prefixes = ("reports/", "__pycache__/", "scripts/__pycache__/")
excluded_files = {"README.md", "result.json"}
files = []
for path in sorted(p for p in HERE.rglob("*") if p.is_file()):
    relative = path.relative_to(HERE).as_posix()
    if relative in excluded_files or relative.startswith(excluded_prefixes):
        continue
    data = path.read_bytes()
    files.append({"path":relative,"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()})
artifact_set_sha256 = hashlib.sha256(canonical_bytes(files)).hexdigest()
manifest = {
    "schema_version": "legendary-paper-restart-e06-artifacts/v1",
    "excluded": ["README.md", "result.json", "reports/**", "**/__pycache__/**"],
    "files": files,
    "artifact_set_sha256": artifact_set_sha256,
}
(HERE / "reports").mkdir(parents=True, exist_ok=True)
(HERE / "reports" / "artifact-hashes.json").write_bytes(canonical_bytes(manifest))

verification = json.loads((HERE / "reports" / "verification.json").read_text())
replay = json.loads((HERE / "reports" / "replay.json").read_text())
reader_matrix = json.loads((HERE / "generated" / "receipts" / "reader-matrix.json").read_text())
hard_gates = verification["hard_gates"]
result = {
    "schema_version": "legendary-paper-restart-experiment-result/v1",
    "assignment_id": "restart-experiment-06",
    "assignment_uuid": "1ecba0d8-c709-47f5-8bf8-a230d6bef4c2",
    "agent_type": "legendary-experimenter",
    "model_reasoning_effort": "medium",
    "round": "diverge",
    "status": "completed",
    "verdict": "RUNNABLE_DIVERGE_CANDIDATE_WITH_BLOCKED_REAL_READERS",
    "candidate_kind": "versioned_canonical_projection",
    "candidate_selected": False,
    "authority": {
        "epic_id": "task-a768c69e659add58",
        "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart",
        "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
        "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc",
    },
    "projection": {"schema":"barkpark.paper.canonical-projection/v1","version":1,"papers":4,"identity_domains_per_paper":6},
    "preservation": {"blocks":"815/815","authored_headers":"113/113","table_body_cells":"1374/1374","marks":"388/388","raw_sources_byte_exact":"4/4","authored_loss":0,"invented_headers":0},
    "adapters": {"public":4,"studio":4,"tui80":4,"email":4,"cli_api":8,"carrier_visibility":"12910/12910"},
    "conditional_validators": "24/24",
    "replay": {"runs":2,"byte_identical":replay["byte_identical"],"current_matches_replay":replay["current_matches_replay"],"generated_file_count":replay["file_count"],"manifest_sha256":replay["manifest_sha256"]},
    "recovery": {"rollback_simulation":"PASS","quarantined_conflicts":1,"source_mutations":0},
    "hard_gates": {"pass":sum(value == "PASS" for value in hard_gates.values()),"fail":sum(value.startswith("FAIL") for value in hard_gates.values()),"blocked":sum(value.startswith("BLOCKED") for value in hard_gates.values()),"details":hard_gates},
    "blocked_real_readers": reader_matrix["real_reader_cells"],
    "proxy_passes": 0,
    "verification_status": verification["status"],
    "artifact_set_sha256": artifact_set_sha256,
    "evidence_archive_sha256": digest(archive_path),
    "recommendation": "HAND_TO_ATTACK; do not select a format until hostile real-reader and lifecycle probes clear every blocked or hard-gate cell.",
}
(HERE / "result.json").write_bytes(canonical_bytes(result))
print(json.dumps({"result_sha256":digest(HERE / "result.json"),"artifact_set_sha256":artifact_set_sha256,"evidence_archive_sha256":digest(archive_path)}, sort_keys=True, separators=(",", ":")))
