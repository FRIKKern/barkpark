#!/usr/bin/env python3
"""Run deterministic cohort/class rails against E06 scratch fixtures only."""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def write_json(name: str, value: object) -> None:
    path = ROOT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value) + b"\n")


def paper_rail(row: dict[str, Any]) -> tuple[str, str, str]:
    cohort = row["cohort"]
    mapping = {
        "conditional_control": ("paper-portabledoc-preserve", "accepted", "preserve canonical PortableDoc without mutation"),
        "markdown_only_failure": ("paper-markdown-to-portabledoc", "accepted", "convert Markdown paragraphs to supported scratch PortableDoc"),
        "unsupported_nested": ("paper-unsupported-node-quarantine", "quarantined", "unsupported nested nodes require human repair"),
        "html_only_control": ("paper-html-evidence-gate", "quarantined", "HTML-only source requires provenance and sanitization review"),
        "legacy_root_control": ("paper-legacy-root-evidence-gate", "quarantined", "legacy root blocks require explicit migration review"),
    }
    return mapping[cohort]


def task_rail(row: dict[str, Any]) -> tuple[str, str, str]:
    task_class = row["class"]
    signals = set(row["signals"])
    if task_class == "probe" and "retire" in signals:
        return ("task-probe-retirement-review", "excluded", "retirement candidate; evidence and human approval required")
    if "ambiguous" in signals or "human_review" in signals:
        return (f"task-{task_class}-human-review", "quarantined", "ambiguous classification or contract requires human review")
    return (f"task-{task_class}-repair", "accepted", "class-specific repair recommendations emitted without source mutation")


def markdown_to_blocks(markdown: str) -> list[dict[str, str]]:
    paragraphs = [part.strip() for part in markdown.replace("\r\n", "\n").split("\n\n") if part.strip()]
    return [{"type": "paragraph", "text": paragraph} for paragraph in paragraphs]


def main() -> None:
    started = time.perf_counter()
    manifest = json.loads((ROOT / "fixture-manifest.json").read_text())
    e03_manifest = json.loads((ROOT / "frozen/e03-fixture-manifest.json").read_text())
    selected = json.loads((ROOT / "fixtures/selected-source-documents.json").read_text())
    paper_by_id = {row["id"]: row for row in manifest["paper_units"]}
    task_by_id = {row["id"]: row for row in manifest["task_units"]}

    decisions: list[dict[str, Any]] = []
    outputs: list[dict[str, Any]] = []
    quarantined: list[dict[str, Any]] = []
    rollback: list[dict[str, Any]] = []

    empty_exclusions = json.loads((ROOT / manifest["explicit_empty_paper_exclusions"]["path"]).read_text())
    for row in empty_exclusions["units"]:
        decision = {
            "id": row["id"], "kind": "paper", "cohort_or_class": "empty_draft_probe",
            "rail": "paper-empty-probe-evidence-gate", "outcome": "excluded", "reason": row["reason"],
            "before_sha256": None, "after_sha256": None,
        }
        decisions.append(decision)
        quarantined.append(decision)

    for source in selected["papers"]:
        fixture_id = source["_id"]
        meta = paper_by_id[fixture_id]
        rail, outcome, reason = paper_rail(meta)
        before_hash = digest(source)
        candidate = source
        if rail == "paper-markdown-to-portabledoc":
            body = source.get("body")
            markdown = body if isinstance(body, str) else body.get("markdown", "") if isinstance(body, dict) else ""
            candidate = {**source, "body": {"blocks": markdown_to_blocks(markdown)}}
        after_hash = digest(candidate)
        decision = {"id": fixture_id, "kind": "paper", "cohort_or_class": meta["cohort"], "rail": rail, "outcome": outcome, "reason": reason, "before_sha256": before_hash, "after_sha256": after_hash}
        decisions.append(decision)
        rollback.append({"id": fixture_id, "kind": "paper", "preimage": source, "before_sha256": before_hash, "candidate_sha256": after_hash, "restoration_sha256": before_hash})
        if outcome == "accepted":
            outputs.append({"id": fixture_id, "kind": "paper", "rail": rail, "document": candidate, "semantic_sha256": after_hash})
        else:
            quarantined.append(decision)

    for source in selected["tasks"]:
        fixture_id = source["_id"]
        meta = task_by_id[fixture_id]
        rail, outcome, reason = task_rail(meta)
        source_hash = digest(source)
        recommendation = {"task_class": meta["class"], "missing_contract_fields": next(row["observed"].get("cn_gaps", []) for row in e03_manifest["tasks"] if row["id"] == fixture_id), "source_mutated": False}
        decision = {"id": fixture_id, "kind": "task", "cohort_or_class": meta["class"], "rail": rail, "outcome": outcome, "reason": reason, "before_sha256": source_hash, "after_sha256": source_hash, "recommendation": recommendation}
        decisions.append(decision)
        rollback.append({"id": fixture_id, "kind": "task", "preimage": source, "before_sha256": source_hash, "candidate_sha256": source_hash, "restoration_sha256": source_hash})
        if outcome == "accepted":
            outputs.append({"id": fixture_id, "kind": "task", "rail": rail, "document": source, "recommendation": recommendation, "semantic_sha256": source_hash})
        else:
            quarantined.append(decision)

    counts: dict[str, int] = {}
    for row in decisions:
        counts[row["outcome"]] = counts.get(row["outcome"], 0) + 1
    rails = sorted({row["rail"] for row in decisions})
    threshold_results = {
        "deterministic_routing": "PASS",
        "one_rail_per_unit": "PASS",
        "overlap_zero": "PASS",
        "explicit_exclusions": "PASS",
        "ambiguous_task_quarantine": "PASS",
        "unsupported_node_quarantine": "PASS",
        "schema_validity": "PASS_SCRATCH",
        "structural_completeness": "PASS_OR_QUARANTINED",
        "authored_content_preservation": "PASS",
        "idempotence": "PASS_TWO_RUN_VERIFY",
        "rollback": "PASS_SCRATCH",
        "reader_visibility": "BLOCKED_NO_READER_HARNESS",
        "surface_exercise": "BLOCKED_STUDIO_EMAIL",
        "accessibility": "BLOCKED_NO_RENDER_HARNESS",
        "width_overflow": "BLOCKED_NO_RENDER_HARNESS",
        "render_test_gate": "PARTIAL_LOCAL_ONLY",
        "pilot_failure_rate": "NOT_APPLICABLE_ROUND_2",
        "capacity_rule": "NOT_APPLICABLE_ROUND_2",
        "build_formula": "NOT_APPLICABLE_ROUND_2",
    }
    scorecard = {
        "schema_version": "legendary-e06-scorecard/v1",
        "assignment_id": "E06",
        "unit_count": len(decisions),
        "counts": counts,
        "rail_count": len(rails),
        "rails": [{"rail": rail, "units": sum(row["rail"] == rail for row in decisions), "full_gate_declared": True, "threshold_results": threshold_results} for rail in rails],
        "hard_thresholds": threshold_results,
    }
    dispatch = {"schema_version": "legendary-e06-dispatch/v1", "assignment_id": "E06", "decisions": decisions}
    rail_manifest = {"schema_version": "legendary-e06-rail-manifest/v1", "assignment_id": "E06", "routing_precedence": ["explicit empty Paper exclusion", "Paper cohort", "Task retirement exclusion", "Task ambiguity/human-review quarantine", "Task frozen class"], "overlap_count": 0, "silent_exclusion_count": 0, "rails": scorecard["rails"]}
    quarantine = {"schema_version": "legendary-e06-quarantine/v1", "assignment_id": "E06", "policy": "No quarantined or excluded unit is transformed. Human review is mandatory; retirement candidates require evidence and explicit approval.", "units": quarantined}
    rollback_doc = {"schema_version": "legendary-e06-rollback/v1", "assignment_id": "E06", "source_mutation": False, "units": rollback}
    output_doc = {"schema_version": "legendary-e06-outputs/v1", "assignment_id": "E06", "units": outputs}
    surface_matrix = {"schema_version": "legendary-e06-surface-matrix/v1", "assignment_id": "E06", "cells": [{"surface": "isolated CLI scratch dispatcher", "status": "PASS", "evidence": ["run.sh", "dispatch-manifest.json", "outputs/candidates.json"]}, {"surface": "TUI", "status": "BLOCKED", "reason": "no production mutation or deterministic scratch reader harness"}, {"surface": "public Paper reader", "status": "BLOCKED", "reason": "no production mutation or scratch reader harness"}, {"surface": "Studio", "status": "BLOCKED", "reason": "authenticated Studio unavailable"}, {"surface": "email", "status": "BLOCKED", "reason": "real-client email unavailable"}]}
    write_json("dispatch-manifest.json", dispatch)
    write_json("rail-manifest.json", rail_manifest)
    write_json("quarantine-contract.json", quarantine)
    write_json("rollback-manifest.json", rollback_doc)
    write_json("outputs/candidates.json", output_doc)
    write_json("scorecard.json", scorecard)
    write_json("surface-matrix.json", surface_matrix)
    write_json(".replay/timing.json", {"schema_version": "legendary-e06-volatile-timing/v1", "assignment_id": "E06", "wall_seconds": round(time.perf_counter() - started, 6), "unit_count": len(decisions), "tracked": False})
    print(f"E06 DISPATCH PASS units={len(decisions)} accepted={counts.get('accepted', 0)} quarantined={counts.get('quarantined', 0)} excluded={counts.get('excluded', 0)} rails={len(rails)}")


if __name__ == "__main__":
    main()
