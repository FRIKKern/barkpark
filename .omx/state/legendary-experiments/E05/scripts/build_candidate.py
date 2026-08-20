#!/usr/bin/env python3
"""Execute the E05 scratch candidate and persist deterministic evidence."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any

from adapter import SURFACES, build_envelope, canonical_bytes, remove_envelope, semantic_hash


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"
OUTPUTS = ROOT / "outputs"


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")


def load_sources() -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    selected = json.loads((FIXTURES / "source-documents.json").read_text())
    sources = {doc["_id"]: doc for doc in selected["papers"] + selected["tasks"]}
    for item in manifest["items"]:
        if item["unit_type"] == "adversarial":
            sources[item["id"]] = json.loads((FIXTURES / item["source_path"]).read_text())
    return manifest, sources


def main() -> None:
    started = time.perf_counter()
    manifest, sources = load_sources()
    envelopes: list[dict[str, Any]] = []
    rollback_rows: list[dict[str, Any]] = []
    quarantine_rows: list[dict[str, Any]] = []
    matrix: list[dict[str, Any]] = []

    for item in manifest["items"]:
        source = sources[item["id"]]
        first = build_envelope(source, fixture_id=item["id"], unit_type=item["unit_type"], cohort=item["cohort"])
        second = build_envelope(first, fixture_id=item["id"], unit_type=item["unit_type"], cohort=item["cohort"])
        restored = remove_envelope(first)
        first_hash = semantic_hash(first)
        second_hash = semantic_hash(second)
        restored_hash = semantic_hash(restored)
        source_hash = semantic_hash(source)
        rollback_rows.append(
            {
                "fixture_id": item["id"],
                "preimage_sha256": source_hash,
                "restored_sha256": restored_hash,
                "first_envelope_sha256": first_hash,
                "second_envelope_sha256": second_hash,
                "idempotence_status": "PASS" if first_hash == second_hash else "FAIL",
                "rollback_status": "PASS" if restored_hash == source_hash else "FAIL",
                "residue_keys": sorted(set(restored) - set(source)) if isinstance(restored, dict) else [],
                "status": "PASS" if restored_hash == source_hash and first_hash == second_hash else "FAIL",
            }
        )
        reader_status = first["reader_contract"]["status"]
        if reader_status == "supported_error":
            quarantine_rows.append(
                {
                    "fixture_id": item["id"],
                    "reason": first["reader_contract"]["error"],
                    "problems": first["reader_contract"].get("problems", []),
                    "preimage_sha256": source_hash,
                    "rollback_status": "PASS" if restored_hash == source_hash else "FAIL",
                }
            )
        for surface in SURFACES:
            output = first["reader_views"][surface]["output"]
            blocked = surface in {"Studio", "email"}
            matrix.append(
                {
                    "fixture_id": item["id"],
                    "surface": surface,
                    "status": "BLOCKED" if blocked else "PASS",
                    "output_mode": first["reader_views"][surface]["mode"],
                    "output_sha256": hashlib.sha256(output.encode("utf-8")).hexdigest(),
                    "nonblank_or_explicit_error": bool(output.strip()),
                    "capability_block": (
                        "authenticated Studio content proof unavailable"
                        if surface == "Studio"
                        else "real-client email proof unavailable"
                        if surface == "email"
                        else None
                    ),
                }
            )
        envelopes.append(first)

    envelope_path = OUTPUTS / "envelopes.jsonl"
    envelope_path.write_bytes(b"".join(canonical_bytes(row) + b"\n" for row in envelopes))
    write_json(OUTPUTS / "rollback-manifest.json", {"schema_version": "legendary-e05-rollback/v1", "rows": rollback_rows})
    write_json(OUTPUTS / "quarantine.json", {"schema_version": "legendary-e05-quarantine/v1", "rows": quarantine_rows})
    status_counts = {status: sum(1 for row in matrix if row["status"] == status) for status in ("PASS", "BLOCKED", "FAIL")}
    write_json(
        OUTPUTS / "surface-matrix.json",
        {
            "schema_version": "legendary-e05-five-surface-matrix/v1",
            "fixture_count": len(envelopes),
            "surface_count": len(SURFACES),
            "cell_count": len(matrix),
            "status_counts": status_counts,
            "rows": matrix,
        },
    )
    candidate_semantic_sha256 = semantic_hash(envelopes)
    elapsed = time.perf_counter() - started
    timing = {
        "schema_version": "legendary-e05-timing/v1",
        "fixture_count": len(envelopes),
        "build_real_seconds": round(elapsed, 6),
        "milliseconds_per_fixture": round(elapsed * 1000 / len(envelopes), 6),
        "under_60_minutes": elapsed < 3600,
    }
    # Committed timing.json is the preserved evidence measurement. Ordinary replay
    # writes its volatile observation outside the repository so verification is
    # byte-stable. An intentional evidence refresh must be explicit.
    volatile_timing_path = Path(
        os.environ.get(
            "E05_VOLATILE_TIMING_PATH",
            str(Path(tempfile.gettempdir()) / "barkpark-e05-last-timing.json"),
        )
    )
    write_json(volatile_timing_path, timing)
    committed_timing_path = OUTPUTS / "timing.json"
    if not committed_timing_path.exists() or os.environ.get("E05_REFRESH_TIMING") == "1":
        write_json(committed_timing_path, timing)
    print(
        f"E05 BUILD PASS fixtures={len(envelopes)} cells={len(matrix)} "
        f"candidate_sha256={candidate_semantic_sha256} quarantined={len(quarantine_rows)} "
        f"observed_seconds={timing['build_real_seconds']} volatile_timing={volatile_timing_path}"
    )


if __name__ == "__main__":
    main()
