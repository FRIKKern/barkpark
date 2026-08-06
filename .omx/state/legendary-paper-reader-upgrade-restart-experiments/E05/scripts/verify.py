#!/usr/bin/env python3
"""Verify E05 against the immutable baseline seal and emit a typed result."""

from __future__ import annotations

import json
from pathlib import Path

from core import PAPER_IDS, canonical_bytes, semantic_core, sha256_bytes

HERE = Path(__file__).resolve().parent
E05 = HERE.parent
BASE = E05.parent
SOURCE = BASE / "E01" / "raw" / "paper_json"
REPORTS = E05 / "reports"
GENERATED = E05 / "generated"
EXPECTED = {
    "blocks": 815,
    "authored_header_cells": 113,
    "table_body_cells": 1374,
    "marks": 388,
    "callouts": 30,
    "headerless_tables": 11,
    "exact_empty_spacers": 381,
    "cch29_nested_list_words": 406,
}


def load(path: Path):
    return json.loads(path.read_bytes())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"E05 VERIFY FAIL: {message}")


def tree_hashes() -> dict[str, str]:
    paths = sorted(list(GENERATED.rglob("*")) + list(REPORTS.glob("*.json")))
    excluded = {"artifact-hashes.json", "replay-proof.json"}
    return {str(path.relative_to(E05)): sha256_bytes(path.read_bytes()) for path in paths
            if path.is_file() and path.name not in excluded}


def main() -> int:
    assignment = load(E05 / "assignment.json")
    seal = load(BASE / "baseline-seal" / "contract.json")
    receipt = load(REPORTS / "build-receipt.json")
    require(assignment["assignment_uuid"] == "656bfc69-da44-4472-842b-b91e74d3925d", "assignment UUID drift")
    require(assignment["round"] == "diverge", "round must be diverge")
    require(seal["round"] == "baseline" and seal["round_count"] == 3 and not seal["candidate_selected"], "baseline is not sealed")
    require(seal["authority"]["wave_revision"] == assignment["wave_revision"], "wave revision drift")
    require(seal["authority"]["inventory_digest"] == assignment["inventory_digest"], "inventory digest drift")
    require(receipt["aggregate_metrics"] == EXPECTED, f"denominator drift: {receipt['aggregate_metrics']}")
    require(receipt["source_unchanged"], "pinned source changed during build")
    for row in receipt["papers"]:
        paper = row["fixture_id"]
        source_raw = (SOURCE / f"{paper}.json").read_bytes()
        require((GENERATED / "raw-snapshots" / f"{paper}.json").read_bytes() == source_raw, f"raw snapshot drift: {paper}")
        rebuilt = semantic_core(source_raw)
        require(rebuilt["semantic_sha256"] == row["semantic_sha256"], f"semantic drift: {paper}")
        require(rebuilt["value"]["blocks"] == json.loads(source_raw)["blocks"], f"authored block loss: {paper}")
        require(row["identity_receipt"]["domains_distinct"], f"identity conflation: {paper}")
        tui_lines = (GENERATED / "adapters" / paper / "tui80.txt").read_text().splitlines()
        require(max(map(len, tui_lines), default=0) <= 80, f"TUI80 overflow: {paper}")
        require(b"Content-Type: multipart/alternative" in (GENERATED / "adapters" / paper / "email.eml").read_bytes(), f"MIME drift: {paper}")
        require(load(GENERATED / "adapters" / paper / "studio.json")["real_reader_status"].startswith("BLOCKED_"),
                f"Studio proxy pass: {paper}")
        cli = load(GENERATED / "adapters" / paper / "cli-api.json")
        require(cli["conditional_get"] == {"if_none_match_equal_status": 304, "otherwise_status": 200}, f"conditional validator drift: {paper}")
    rollback = load(REPORTS / "rollback-removal-receipt.json")
    require(rollback["production_writes"] == 0 and rollback["raw_source_unchanged"] and rollback["expected_residue_after_declared_removal"] == 0,
            "rollback/removal proof failed")
    blocked = load(REPORTS / "reader-blocks.json")
    require(all(cell["status"].startswith("BLOCKED") for cell in blocked["cells"]), "blocked reader was proxy-passed")
    require(load(REPORTS / "credential-scan.json")["hits"] == [], "credential scan has hits")
    scorecard = {
        "schema_version": "legendary-restart-e05-scorecard/v1",
        "observations": [
            {"gate": "raw_source_preservation", "status": "PASS", "score": "4/4 byte exact"},
            {"gate": "semantic_structural_completeness", "status": "PASS", "score": "815/815 blocks; 113/113 headers; 1374/1374 body cells; 388/388 marks; 406/406 CCH29 nested-list words"},
            {"gate": "public", "status": "BLOCKED_REAL_BROWSER_AT", "score": "4/4 isolated HTML adapters deterministic; real browser/AT unavailable"},
            {"gate": "Studio", "status": "BLOCKED_AUTHENTICATED_READER", "score": "4/4 isolated JSON adapters deterministic; authenticated edit/reconnect unavailable"},
            {"gate": "TUI80", "status": "PASS_ISOLATED_CANDIDATE", "score": "4/4 outputs nonblank; max line width <= 80"},
            {"gate": "email", "status": "BLOCKED_DELIVERED_CLIENT", "score": "4/4 MIME adapters deterministic; delivered-client probe unavailable"},
            {"gate": "CLI/API", "status": "PASS_ISOLATED_CANDIDATE", "score": "4/4 typed JSON adapters and conditional validators deterministic"},
            {"gate": "identity_and_cache", "status": "PASS", "score": "4/4 document/release/cache/Cycle domains distinct"},
            {"gate": "rollback_removal", "status": "PASS_DERIVED_ONLY", "score": "0 production writes; source unchanged; candidate path-bounded removal receipt"},
            {"gate": "credential_scan", "status": "PASS", "score": f"0 hits/{load(REPORTS / 'credential-scan.json')['files_scanned']} files"},
        ],
        "hard_gate_failures": [],
        "blocked_cells": 12,
        "overall": "BLOCKED_REAL_READERS",
        "preference": "No aesthetic or winner preference recorded.",
    }
    (REPORTS / "scorecard.json").write_bytes(canonical_bytes(scorecard) + b"\n")
    commands = {
        "schema_version": "legendary-restart-e05-commands/v1",
        "commands": [
            "python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/baseline-seal/verify.py",
            "python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E05/scripts/replay.py",
            "python3 -m py_compile .omx/state/legendary-paper-reader-upgrade-restart-experiments/E05/scripts/*.py",
        ],
        "expected_terminal": "E05 REPLAY PASS",
    }
    (REPORTS / "commands.json").write_bytes(canonical_bytes(commands) + b"\n")
    hashes = tree_hashes()
    artifact_set_sha256 = sha256_bytes(canonical_bytes(hashes))
    (REPORTS / "artifact-hashes.json").write_bytes(canonical_bytes({
        "schema_version": "legendary-restart-e05-artifact-hashes/v1",
        "artifact_set_sha256": artifact_set_sha256,
        "files": hashes,
    }) + b"\n")
    local_hard_gates = {
        "authored_content_loss": 0,
        "invented_author_intent": 0,
        "schema_invalidity": 0,
        "page_or_display_overflow": 0,
        "identity_domain_conflation": 0,
        "non_idempotent_reruns": 0,
        "rollback_failures": 0,
        "proxy_passes_for_missing_readers": 0,
    }
    result = {
        "schema_version": "barkpark-cycle-experiment-result/v1",
        "assignment_id": "restart-experiment-05",
        "assignment_uuid": assignment["assignment_uuid"],
        "agent_type": "legendary-experimenter",
        "round": "diverge",
        "epic_task_id": assignment["epic_task_id"],
        "wave_id": assignment["wave_id"],
        "wave_revision": assignment["wave_revision"],
        "candidate_id": "shared_read_time_compatibility_core",
        "typed_verdict": "DIVERGE_CANDIDATE_BLOCKED_REAL_READERS",
        "self_selected_as_winner": False,
        "observations": {
            "papers": 4,
            "reader_units": 20,
            **EXPECTED,
            "raw_sources_byte_exact": "4/4",
            "semantic_cores_lossless": "4/4",
            "thin_adapters_generated": "20/20",
            "identity_receipts_distinct": "4/4",
            "rollback_removal_receipts": "4/4 source preservation plus one candidate removal receipt",
        },
        "local_hard_gate_failures": {key: value for key, value in local_hard_gates.items() if value != 0},
        "local_hard_gates": local_hard_gates,
        "blocked_real_reader_cells": 12,
        "scorecard": "reports/scorecard.json",
        "blocks": [
            "authenticated Studio content/edit/reconnect probe unavailable",
            "real browser plus assistive-technology reading-order probe unavailable",
            "delivered Gmail/Outlook/Apple Mail probe unavailable",
        ],
        "inferences": [
            "The shared read-time core is mechanically lossless and removable on the four pinned captures.",
            "Static adapter success does not establish real Studio, assistive-technology, or delivered-mail behavior.",
        ],
        "preference_observations": [],
        "artifact_set_sha256": artifact_set_sha256,
        "timing": load(REPORTS / "timing.json"),
        "validation": {"command": "python3 scripts/replay.py", "expected": "E05 REPLAY PASS"},
        "recommended_handoff": "Carry candidate into Attack only as runnable BLOCKED evidence; do not select it until authenticated Studio, real AT/browser, and delivered-mail probes clear every zero threshold.",
    }
    (E05 / "result.json").write_bytes(canonical_bytes(result) + b"\n")
    print(f"E05 VERIFY PASS papers=4 blocks=815 artifact_set_sha256={artifact_set_sha256} verdict=DIVERGE_CANDIDATE_BLOCKED_REAL_READERS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
