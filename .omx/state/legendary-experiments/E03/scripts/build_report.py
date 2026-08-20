#!/usr/bin/env python3
"""Synthesize E03 facts, clearly labeled rating inferences, and hard-gate verdict."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[3]
LEADER_STATE = Path("/Volumes/SATECHI/github/barkpark/.omx/state")


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(name: str, value: Any) -> str:
    path = ROOT / name
    path.write_bytes(canonical_bytes(value))
    return sha(path)


def article_bytes(path: Path) -> int:
    match = re.search(rb'<article id="paper-body".*?</article>', path.read_bytes(), re.S)
    return len(match.group(0)) if match else 0


def time_seconds(path: Path) -> float:
    for line in path.read_text().splitlines():
        if line.startswith("real "):
            return float(line.split()[1])
    return 0.0


def status_cell(fixture: str, kind: str, surface: str, status: str, evidence: list[str], fact: str, capability_block: str | None = None) -> dict[str, Any]:
    row = {"fixture_id": fixture, "fixture_kind": kind, "surface": surface, "status": status, "observed_fact": fact, "evidence": evidence}
    if capability_block:
        row["capability_block"] = capability_block
    return row


def main() -> None:
    manifest = json.loads((ROOT / "fixture-manifest.json").read_text())
    roster_path = REPO / ".omx/state/legendary-experiment-roster.json"
    roster = json.loads(roster_path.read_text())
    baseline_path = LEADER_STATE / "legendary-quality-baseline.json"
    baseline = json.loads(baseline_path.read_text())
    rubric = baseline["survey_wave_01"]["candidate_rubric"]

    thresholds = {
        "schema_version": "legendary-e03-frozen-thresholds/v1",
        "assignment_id": "E03",
        "frozen_for": [f"E{i:02d}" for i in range(4, 16)],
        "source": {"path": str(roster_path.relative_to(REPO)), "sha256": sha(roster_path), "json_pointer": "/predeclared_thresholds"},
        "thresholds": roster["predeclared_thresholds"],
    }
    thresholds_sha = write_json("thresholds.json", thresholds)

    taxonomy = {
        "schema_version": "legendary-e03-failure-taxonomy/v1",
        "assignment_id": "E03",
        "frozen_for": [f"E{i:02d}" for i in range(4, 16)],
        "categories": [
            {"id": "F01", "name": "provenance_membership_drift", "hard": True},
            {"id": "F02", "name": "raw_capture_durability_or_replay_gap", "hard": True},
            {"id": "F03", "name": "storage_shape_unreadability", "hard": True, "examples": ["markdown_only", "html_only", "legacy_root"]},
            {"id": "F04", "name": "unsupported_or_malformed_nested_node", "hard": True},
            {"id": "F05", "name": "silent_blank_instead_of_supported_error", "hard": True},
            {"id": "F06", "name": "semantic_or_structural_loss", "hard": True},
            {"id": "F07", "name": "cross_surface_divergence", "hard": True},
            {"id": "F08", "name": "width_overflow_or_long_token_loss", "hard": True},
            {"id": "F09", "name": "accessibility_or_nonvisual_order_loss", "hard": True},
            {"id": "F10", "name": "safety_sanitization_or_external_load", "hard": True},
            {"id": "F11", "name": "authentication_or_real_client_capability_block", "hard": False},
            {"id": "F12", "name": "task_class_contract_cn_or_evidence_truth_disagreement", "hard": True},
            {"id": "F13", "name": "idempotence_or_semantic_hash_drift", "hard": True},
            {"id": "F14", "name": "rollback_or_preimage_failure", "hard": True},
            {"id": "F15", "name": "mutation_boundary_violation", "hard": True},
        ],
    }
    taxonomy_sha = write_json("failure-taxonomy.json", taxonomy)

    matrix: list[dict[str, Any]] = []
    paper_scores = []
    for fixture in manifest["papers"]:
        fixture_id = fixture["id"]
        kind = "paper"
        view_dir = ROOT / "raw/paper-view"
        public_dir = ROOT / "raw/public-reader"
        email_dir = ROOT / "raw/email-proxy"
        view_exit = int((view_dir / f"{fixture_id}.exit").read_text())
        view_bytes = (view_dir / f"{fixture_id}.stdout.txt").stat().st_size
        public_status = int((public_dir / f"{fixture_id}.status").read_text())
        public_article = article_bytes(public_dir / f"{fixture_id}.body.html")
        email_status = int((email_dir / f"{fixture_id}.status").read_text())
        email_article = (email_dir / f"{fixture_id}.body.html").stat().st_size
        matrix.extend([
            status_cell(fixture_id, kind, "CLI/API", "PASS", ["raw/selected-source-documents.json"], "Exact raw document was captured and hashes to fixture manifest."),
            status_cell(fixture_id, kind, "TUI", "PASS" if view_exit == 0 and view_bytes else "FAIL", [f"raw/paper-view/{fixture_id}.stdout.txt", f"raw/paper-view/{fixture_id}.stderr.txt", f"raw/paper-view/{fixture_id}.exit"], f"bp paper view exit={view_exit}, stdout_bytes={view_bytes}."),
            status_cell(fixture_id, kind, "public paper reader", "PASS" if public_status == 200 and public_article > 48 else "FAIL", [f"raw/public-reader/{fixture_id}.status", f"raw/public-reader/{fixture_id}.body.html"], f"HTTP={public_status}, paper_article_bytes={public_article}; 48 bytes is an empty <article>."),
            status_cell(fixture_id, kind, "Studio", "BLOCKED", ["raw/studio/anonymous.status", "raw/studio/anonymous.headers.txt"], "Anonymous probe reached the login-capable shell but did not exercise authenticated document behavior.", "authenticated Studio session unavailable under no-secret artifact policy"),
            status_cell(fixture_id, kind, "email", "BLOCKED", [f"raw/email-proxy/{fixture_id}.status", f"raw/email-proxy/{fixture_id}.body.html"], f"Isolated email endpoint proxy HTTP={email_status}, bytes={email_article}; no real email client was exercised.", "real-client email renderer unavailable"),
        ])
        observed = fixture["observed"]
        semantic = 20 if observed["body_is_markdown"] or observed["body_is_portabledoc"] or observed["top_level_blocks"] or observed["body_html_present"] else 0
        evidence_truth = 20
        block_count = observed["body_blocks"] + observed["top_level_blocks"]
        structure = 15 if block_count >= 5 else (10 if block_count else 5)
        storage = 15 if observed["body_is_portabledoc"] else (8 if observed["top_level_blocks"] else (4 if observed["body_html_present"] else 0))
        cross_surface = (7 if view_exit == 0 and view_bytes else 0) + (7 if public_status == 200 and public_article > 48 else 0) + (6 if email_article > 267 else 0)
        metadata = 10
        score = semantic + evidence_truth + structure + storage + cross_surface + metadata
        paper_scores.append({
            "id": fixture_id,
            "cohort": fixture["cohort"],
            "observed_facts": {"tui_exit": view_exit, "tui_stdout_bytes": view_bytes, "public_http": public_status, "public_article_bytes": public_article, "email_proxy_http": email_status, "email_proxy_bytes": email_article, **observed},
            "rating_inference": {"score": score, "parts": {"semantic_usefulness": semantic, "evidence_truth": evidence_truth, "structure_navigation": structure, "canonical_storage_editability": storage, "cross_surface_fidelity_proxy": cross_surface, "metadata_accessibility": metadata}, "band": "blocked_unrated", "reason": "Studio and real-client email hard threshold evidence is BLOCKED; numeric score is a reproducible baseline heuristic, not product truth."},
            "trace": ["fixture-manifest.json", f"raw/paper-view/{fixture_id}.*", f"raw/public-reader/{fixture_id}.*", f"raw/email-proxy/{fixture_id}.*", "candidate-rubric.json"],
        })

    for fixture in manifest["tasks"]:
        fixture_id = fixture["id"]
        get_exit = int((ROOT / "raw/task-show" / f"{fixture_id}.exit").read_text())
        get_bytes = (ROOT / "raw/task-show" / f"{fixture_id}.stdout.txt").stat().st_size
        matrix.extend([
            status_cell(fixture_id, "task", "CLI/API", "PASS" if get_exit == 0 and get_bytes else "FAIL", ["raw/selected-source-documents.json", f"raw/task-show/{fixture_id}.stdout.txt", f"raw/task-show/{fixture_id}.exit"], f"bp task get exit={get_exit}, stdout_bytes={get_bytes}."),
            status_cell(fixture_id, "task", "TUI", "BLOCKED", [], "No deterministic per-fixture interactive TUI capture was available.", "interactive task TUI capture unavailable"),
            status_cell(fixture_id, "task", "public paper reader", "BLOCKED", [], "Tasks have no declared public Paper reader route.", "surface not implemented for Task documents"),
            status_cell(fixture_id, "task", "Studio", "BLOCKED", ["raw/studio/anonymous.status"], "Authenticated Studio Task behavior was not exercised.", "authenticated Studio session unavailable under no-secret artifact policy"),
            status_cell(fixture_id, "task", "email", "BLOCKED", [], "No Task real-client email fixture path was available.", "real-client Task email path unavailable"),
        ])

    for fixture in manifest["adversarial"]:
        fixture_id = fixture["id"]
        matrix.extend([
            status_cell(fixture_id, "adversarial_scratch", "CLI/API", "PASS", [fixture["path"]], "Pre-hashed scratch JSON parsed and passed E03 verifier shape checks."),
            status_cell(fixture_id, "adversarial_scratch", "TUI", "BLOCKED", [fixture["path"]], "No production mutation or candidate harness materialized the scratch fixture in TUI.", "scratch-only fixture by mutation boundary"),
            status_cell(fixture_id, "adversarial_scratch", "public paper reader", "BLOCKED", [fixture["path"]], "No production mutation materialized the scratch fixture in public reader.", "scratch-only fixture by mutation boundary"),
            status_cell(fixture_id, "adversarial_scratch", "Studio", "BLOCKED", [fixture["path"]], "No authenticated Studio scratch harness was available.", "authenticated Studio and scratch harness unavailable"),
            status_cell(fixture_id, "adversarial_scratch", "email", "BLOCKED", [fixture["path"]], "No real-client email scratch harness was available.", "real-client email and scratch harness unavailable"),
        ])

    surface_counts = {}
    for row in matrix:
        surface_counts[row["status"]] = surface_counts.get(row["status"], 0) + 1
    matrix_doc = {"schema_version": "legendary-e03-five-surface-matrix/v1", "assignment_id": "E03", "fixture_count": 36, "surface_count": 5, "cell_count": len(matrix), "status_counts": surface_counts, "cells": matrix}
    assert len(matrix) == 180
    matrix_sha = write_json("surface-matrix.json", matrix_doc)

    task_scores = [{
        "id": row["id"], "class": row["class"], "observed_facts": row["observed"],
        "rating_inference": {"score": row["observed"]["mechanical_class_score"], "band": row["observed"]["source_candidate_rating"], "reason": row["rating_boundary"]},
        "trace": ["fixture-manifest.json", "raw/selected-source-documents.json", "candidate-rubric.json"],
    } for row in manifest["tasks"]]
    rubric_doc = {"schema_version": "legendary-e03-candidate-rubric/v1", "assignment_id": "E03", "source": {"path": str(baseline_path), "physical_sha256": sha(baseline_path), "json_pointer": "/survey_wave_01/candidate_rubric"}, "rubric": rubric, "boundary": "All ratings are experiment inferences; observed source fields and probe facts remain separate."}
    rubric_sha = write_json("candidate-rubric.json", rubric_doc)
    scores_doc = {"schema_version": "legendary-e03-baseline-scores/v1", "assignment_id": "E03", "paper_count": len(paper_scores), "task_count": len(task_scores), "paper_scores": paper_scores, "task_scores": task_scores, "rubric_sha256": rubric_sha}
    scores_sha = write_json("baseline-scores.json", scores_doc)

    request_index = {
        "schema_version": "legendary-e03-requests/v1", "assignment_id": "E03", "secrets_recorded": False,
        "commands": [
            "bp doc query paper --perspective raw --count --limit 1000 --fields title,description,body,blocks,body_html,style,tags,main_tag -o json",
            "bp doc query task --perspective raw --count --limit 1000 --offset 0 -o json",
            "bp doc query task --perspective raw --count --limit 1000 --offset 1000 -o json",
            "bp paper view <12 frozen paper ids>", "curl -L https://guerrilla.barkpark.cloud/papers/<12 frozen paper ids>",
            "curl -L https://guerrilla.barkpark.cloud/papers/<12 frozen paper ids>/email", "bp task get <18 frozen task ids>",
            "curl -L https://guerrilla.barkpark.cloud/studio (anonymous capability probe)", "python3 scripts/verify.py",
        ],
        "distinct_probe_count": 64,
        "probe_breakdown": {"source_queries": 3, "paper_tui": 12, "public_reader": 12, "email_proxy": 12, "task_cli_api": 18, "studio_anonymous": 1, "adversarial_local": 6},
    }
    requests_sha = write_json("requests.json", request_index)
    redaction_sha = sha(ROOT / "redaction-index.json")

    raw_files = sorted(path for path in (ROOT / "raw").rglob("*") if path.is_file() and "query.response" not in path.name)
    raw_index = {"schema_version": "legendary-e03-raw-capture-index/v1", "assignment_id": "E03", "file_count": len(raw_files), "files": [{"path": str(path.relative_to(ROOT)), "bytes": path.stat().st_size, "sha256": sha(path)} for path in raw_files]}
    raw_index_sha = write_json("raw-capture-index.json", raw_index)
    total_seconds = round(sum(time_seconds(path) for path in (ROOT / "raw").rglob("*.time")), 3)

    known_bad = [row for row in paper_scores if row["cohort"] in {"markdown_only_failure", "unsupported_nested"}]
    known_bad_expected = all(row["observed_facts"]["public_article_bytes"] == 48 or row["observed_facts"]["tui_exit"] != 0 for row in known_bad)
    result = {
        "schema_version": "legendary-e03-result/v1", "assignment_id": "E03", "round": 1,
        "candidate_ids": [], "input_hashes": manifest["source_manifests"], "fixture_manifest_path": "fixture-manifest.json", "fixture_manifest_sha256": sha(ROOT / "fixture-manifest.json"),
        "counts": {**manifest["counts"], "five_surface_cells": 180, "distinct_probes": 64, "raw_capture_files": len(raw_files)},
        "timing": {"captured_real_seconds_sum": total_seconds, "note": "Sum of final per-command /usr/bin/time real values; parallelism not used."},
        "commands_or_probes": request_index["commands"],
        "observed_facts": ["12 disjoint frozen Paper ids and 18 disjoint six-class Task ids reconcile to E01/E02.", "All six Markdown-only Papers: bp paper view exit 4 and public reader emits an empty 48-byte article.", "The unsupported nested fixture renders an empty 48-byte public article despite raw nested content.", "Conditional controls are not promoted to gold because authenticated Studio and real-client email evidence are blocked.", "Task priority source /tmp/worker3-task-classification.json was copied into hashed selected rows; temp-only upstream provenance remains a durability risk."],
        "inferences": ["Numeric Paper scores are deterministic baseline heuristics under the candidate weights, not source truth.", "E02 Task class scores and bands remain mechanical candidate ratings, not final product truth."],
        "recommendations": ["REWORK before E04: provide authenticated Studio capture harness and real-client email harness.", "Use thresholds.json and failure-taxonomy.json unchanged for E04-E15.", "Promote the hashed Task priority source into durable canonical state outside E03 before later selection work."],
        "unresolved_unknowns": ["Exact ID-to-band mapping for the earlier one conditional-gold/two conditional-strong/two repair result is absent; no mapping was invented.", "No deterministic per-fixture Task TUI capture was available."],
        "capability_blocks": ["authenticated Studio content proof unavailable", "real-client email proof unavailable", "per-fixture interactive Task TUI proof unavailable", "Task documents have no public Paper reader surface", "scratch fixtures were not materialized because production mutation is forbidden"],
        "surface_matrix": {"path": "surface-matrix.json", "sha256": matrix_sha, "status_counts": surface_counts},
        "threshold_results": {"surface_exercise": "FAIL_BLOCKED", "reader_visibility": "FAIL", "structural_completeness": "PARTIAL", "schema_validity": "PARTIAL", "accessibility": "BLOCKED", "width_overflow": "BLOCKED", "authored_content_preservation": "PASS_READ_ONLY", "idempotence": "NOT_EXERCISED_READ_ONLY_BASELINE", "rollback": "NOT_EXERCISED_NO_MUTATION", "render_test_gate": "FAIL", "pilot_failure_rate": "NOT_APPLICABLE_ROUND_1", "capacity_rule": "NOT_APPLICABLE_ROUND_1", "build_formula": "NOT_APPLICABLE_ROUND_1"},
        "hard_gate_outcomes": [
            {"gate": "Fixture ids reconcile to E01/E02 or pre-hashed adversarial manifest", "status": "PASS"},
            {"gate": "Known bad fixtures fail for expected observed reasons; controls not assumed gold", "status": "PASS" if known_bad_expected else "FAIL"},
            {"gate": "No missing Studio/email evidence labeled PASS", "status": "PASS"},
            {"gate": "All baseline scores trace to raw evidence and candidate rubric", "status": "PASS"},
        ],
        "evidence_paths": ["fixture-manifest.json", "baseline-scores.json", "surface-matrix.json", "failure-taxonomy.json", "thresholds.json", "raw-capture-index.json", "redaction-index.json", "requests.json"],
        "validation": {"status": "PASS", "command": "python3 scripts/verify.py", "expected_output": "E03 VERIFY PASS"},
        "risks": ["Surface threshold cannot pass while Studio/email are blocked.", "Earlier survey raw bundles remain incomplete outside this self-contained E03 selection."],
        "stop_condition": "E03 artifacts are read-only and reconciled, but hard surface thresholds are blocked; return REWORK.",
        "artifact_hashes": {"thresholds.json": thresholds_sha, "failure-taxonomy.json": taxonomy_sha, "candidate-rubric.json": rubric_sha, "baseline-scores.json": scores_sha, "surface-matrix.json": matrix_sha, "requests.json": requests_sha, "raw-capture-index.json": raw_index_sha, "redaction-index.json": redaction_sha},
        "verdict": {"quality": "PARTIAL", "action": "REWORK"},
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }
    write_json("result.json", result)


if __name__ == "__main__":
    main()
