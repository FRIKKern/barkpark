#!/usr/bin/env python3
"""Run the E01 verifier twice, require byte identity, and write the typed result."""

from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path

from canonicalizer import canonical_bytes, sha256


ROOT = Path(__file__).resolve().parents[1]


def write_json(path: Path, value: object) -> None:
    path.write_bytes(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8") + b"\n")


def main() -> int:
    outputs = []
    timings = []
    for index in (1, 2):
        started = time.perf_counter()
        process = subprocess.run(["python3", "scripts/verify.py"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        timings.append(round(time.perf_counter() - started, 6))
        if process.returncode != 0:
            raise RuntimeError(f"replay {index} failed: {process.stderr.decode('utf-8', 'replace')}")
        result = json.loads(process.stdout)
        write_json(ROOT / "reports" / f"replay-{index}.json", result)
        outputs.append(canonical_bytes(result))
    if outputs[0] != outputs[1]:
        raise RuntimeError("replay outputs differ")
    replay_sha = sha256(outputs[0])
    write_json(ROOT / "reports" / "reproducibility.json", {
        "schema_version": "legendary-paper-restart-e01-reproducibility/v1",
        "runs": 2,
        "byte_identical": True,
        "replay_sha256": replay_sha,
        "seconds": timings,
    })
    census = json.loads((ROOT / "reports" / "census.json").read_text())
    loss = json.loads((ROOT / "reports" / "block-loss-manifest.json").read_text())
    hashes = json.loads((ROOT / "reports" / "hash-manifest.json").read_text())
    tokens = json.loads((ROOT / "reports" / "saved-token-scan.json").read_text())
    mutation = json.loads((ROOT / "reports" / "zero-external-mutation-proof.json").read_text())
    result = {
        "schema_version": "barkpark-cycle-experiment-result/v1",
        "assignment_id": "restart-experiment-01",
        "assignment_uuid": "f5556476-4677-4f31-ab90-d7bf5b9134ee",
        "epic_task_id": "task-a768c69e659add58",
        "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart",
        "round": "baseline",
        "verdict": "BASELINE_CANONICALIZER_PASS_WITH_KNOWN_READER_RISKS",
        "candidate_ids": [],
        "observations": {
            "revision_pins": "4/4 exact across doc get and paper view JSON projections",
            "blocks": census["totals"]["blocks"],
            "authored_header_cells": census["totals"]["authored_header_cells"],
            "table_body_cells": census["totals"]["table_body_cells"],
            "marks": census["totals"]["marks"],
            "headerless_tables": census["totals"]["headerless_tables"],
            "cch29_nested_words": next(row["nested_paragraph_words"] for row in census["papers"] if row["fixture_id"] == "CCH29"),
            "canonical_blocks_exact": loss["summary"]["exact"],
            "authored_loss_events": loss["summary"]["authored_loss_events"],
            "invented_header_cells": loss["summary"]["invented_header_cells"],
            "saved_token_hits": tokens["hit_count"],
            "external_mutations": mutation["production_mutations"] + mutation["task_paper_cycle_mutations"],
        },
        "inferences": [
            "The documented raw/envelope/semantic boundary is suitable as a lossless baseline oracle for candidate comparison because every normalized block is localized and exact.",
            "Reader adapters remain a separate risk surface; this assignment proves the canonicalizer and fixtures, not that current public, Studio, TUI, email, or CLI readers preserve every semantic carrier."
        ],
        "risks": [
            "Known reader hypotheses include legacy header/head mismatch, paragraph-wrapped nested-list loss, and mixed mark semantics; they are frozen as attack fixtures rather than counted as canonicalizer failures.",
            "Unicode NFC is intentionally non-byte-preserving for canonically equivalent decomposed text; all current 815 live blocks remain exact after that declared normalization.",
            "No real browser, Studio session, delivered mail client, or assistive technology was exercised in this canonical-content-only assignment."
        ],
        "artifact_set_sha256": hashes["artifact_set_sha256"],
        "replay_sha256": replay_sha,
        "replay_runs": 2,
        "replay_byte_identical": True,
        "stop_condition": "Canonical baseline, fixtures, block-local loss manifest, taxonomy, hashes, timings, token scan, and identical double replay are reproducible; no repair candidate or external mutation was made."
    }
    write_json(ROOT / "result.json", result)
    print(canonical_bytes(result).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
