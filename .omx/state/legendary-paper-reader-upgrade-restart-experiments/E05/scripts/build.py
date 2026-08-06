#!/usr/bin/env python3
"""Build deterministic E05 candidate evidence without mutating pinned sources."""

from __future__ import annotations

import json
import time
from pathlib import Path

from core import ADAPTERS, PAPER_IDS, WAVE_REVISION, canonical_bytes, credential_hits, semantic_core, sha256_bytes, source_metrics

HERE = Path(__file__).resolve().parent
E05 = HERE.parent
ROOT = E05.parents[4]
SOURCE = E05.parent / "E01" / "raw" / "paper_json"
GENERATED = E05 / "generated"
REPORTS = E05 / "reports"


def write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def main() -> int:
    started = time.perf_counter()
    source_before = {paper: sha256_bytes((SOURCE / f"{paper}.json").read_bytes()) for paper in PAPER_IDS}
    papers = []
    aggregate = {key: 0 for key in ("blocks", "authored_header_cells", "table_body_cells", "marks", "callouts",
                                          "headerless_tables", "exact_empty_spacers", "cch29_nested_list_words")}
    for paper in PAPER_IDS:
        raw = (SOURCE / f"{paper}.json").read_bytes()
        core = semantic_core(raw)
        write(GENERATED / "raw-snapshots" / f"{paper}.json", raw)
        write(GENERATED / "semantic" / f"{paper}.json", canonical_bytes(core) + b"\n")
        adapter_hashes = {}
        for filename, adapter in ADAPTERS.items():
            payload = adapter(core)
            write(GENERATED / "adapters" / paper / filename, payload)
            adapter_hashes[filename] = sha256_bytes(payload)
        metrics = source_metrics(core["value"]["blocks"])
        for key, value in metrics.items():
            aggregate[key] += value
        papers.append({
            "fixture_id": paper,
            "raw_source": str((SOURCE / f"{paper}.json").relative_to(ROOT)),
            "raw_sha256": sha256_bytes(raw),
            "semantic_sha256": core["semantic_sha256"],
            "identity_receipt": core["identity_receipt"],
            "metrics": metrics,
            "adapter_hashes": adapter_hashes,
        })
    source_after = {paper: sha256_bytes((SOURCE / f"{paper}.json").read_bytes()) for paper in PAPER_IDS}
    build_receipt = {
        "schema_version": "legendary-restart-e05-build-receipt/v1",
        "candidate": "shared_read_time_compatibility_core",
        "wave_revision": WAVE_REVISION,
        "papers": papers,
        "aggregate_metrics": aggregate,
        "source_before": source_before,
        "source_after": source_after,
        "source_unchanged": source_before == source_after,
    }
    write(REPORTS / "build-receipt.json", canonical_bytes(build_receipt) + b"\n")
    rollback = {
        "schema_version": "legendary-restart-e05-removal-receipt/v1",
        "mutation_model": "read-time derived artifacts only",
        "production_writes": 0,
        "raw_source_unchanged": source_before == source_after,
        "removal_scope": "delete only E05/generated and E05/reports; no pre-image restore required",
        "expected_residue_after_declared_removal": 0,
        "observation_boundary": "No deletion was executed; removal is a path-bounded consequence of the candidate creating only E05-derived files.",
        "quarantine": [],
    }
    write(REPORTS / "rollback-removal-receipt.json", canonical_bytes(rollback) + b"\n")
    blocked = {
        "schema_version": "legendary-restart-e05-reader-blocks/v1",
        "cells": [
            {"surface": "Studio", "status": "BLOCKED", "count": 4, "reason": "authenticated Studio session unavailable; generated Studio adapter is not a proxy pass"},
            {"surface": "public", "status": "BLOCKED_REAL_BROWSER_AT", "count": 4, "reason": "real browser plus assistive-technology session unavailable; static HTML probe is not a proxy pass"},
            {"surface": "email", "status": "BLOCKED_DELIVERED_CLIENT", "count": 4, "reason": "delivered Gmail/Outlook/Apple Mail client unavailable; MIME probe is not a proxy pass"},
        ],
    }
    write(REPORTS / "reader-blocks.json", canonical_bytes(blocked) + b"\n")
    scan_paths = sorted((E05 / "scripts").glob("*.py")) + [E05 / "assignment.json", E05 / "README.md"]
    scan_paths += sorted(path for path in GENERATED.rglob("*") if path.is_file())
    scan = {"schema_version": "legendary-restart-e05-credential-scan/v1", "files_scanned": len(scan_paths), "hits": []}
    for path in scan_paths:
        for kind in credential_hits(path.read_bytes()):
            scan["hits"].append({"path": str(path.relative_to(E05)), "kind": kind})
    write(REPORTS / "credential-scan.json", canonical_bytes(scan) + b"\n")
    timing_path = REPORTS / "timing.json"
    if not timing_path.exists():
        elapsed_ms = round((time.perf_counter() - started) * 1000, 3)
        timing = {"schema_version": "legendary-restart-e05-timing/v1", "papers": 4, "elapsed_ms": elapsed_ms,
                  "milliseconds_per_paper": round(elapsed_ms / 4, 3), "under_60_minutes": elapsed_ms < 3_600_000}
        write(timing_path, canonical_bytes(timing) + b"\n")
    print(f"E05 BUILD PASS papers=4 blocks={aggregate['blocks']} source_unchanged={source_before == source_after}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
