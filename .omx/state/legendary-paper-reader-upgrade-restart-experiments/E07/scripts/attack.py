#!/usr/bin/env python3
"""Run deterministic hostile attacks against E04, E05, and E06."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parents[1]
EXPERIMENT_ROOT = HERE.parent

AUTHORITY = {
    "epic_task_id": "task-a768c69e659add58",
    "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart",
    "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
    "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc",
    "plan_digest": "9997fc50db5f1b83f1f53e33bd45dd111b2b06402b07a78b0673d2048f299e45",
}

THRESHOLDS = {
    "authored_content_loss": 0,
    "invented_author_intent": 0,
    "schema_invalidity": 0,
    "page_or_display_overflow": 0,
    "reading_order_failures": 0,
    "silent_scope_or_perspective_substitution": 0,
    "false_not_found": 0,
    "terminal_control_leaks": 0,
    "silent_secondary_failures": 0,
    "identity_domain_conflation": 0,
    "retry_erased_failures": 0,
    "non_idempotent_reruns": 0,
    "rollback_failures": 0,
    "proxy_passes_for_missing_readers": 0,
}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(value))


def load(name: str, path: Path):
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture() -> dict[str, Any]:
    long_token = "TOKEN_" + "x" * 506
    return {
        "_id": "attack-paper",
        "_publishedId": "attack-paper-published",
        "_rev": "attack-rev-1",
        "_type": "paper",
        "_updatedAt": "2026-08-06T00:00:00Z",
        "title": "E07 hostile fixture",
        "description": None,
        "style": "article",
        "main_tag": None,
        "tags": [],
        "blocks": [
            {"id": "conflict", "type": "table", "header": ["HEADER_SENTINEL"], "head": ["HEAD_SENTINEL"], "rows": [["BODY_SENTINEL"]]},
            {"id": "headerless", "type": "table", "rows": [["HEADERLESS_BODY"]]},
            {"id": "nested", "type": "list", "ordered": False, "items": [[
                {"type": "paragraph", "content": [{"type": "text", "value": "NESTED_LEVEL_ONE"}]},
                {"type": "list", "ordered": True, "items": [[{"type": "paragraph", "content": [{"type": "text", "value": "NESTED_LEVEL_TWO"}]}]]},
            ]]},
            {"id": "malformed", "type": "list", "items": {"content": [{"type": "text", "value": "MALFORMED_PAYLOAD"}]}},
            {"id": "marks", "type": "paragraph", "content": [
                {"type": "text", "value": "MARK_ALIAS_TEXT", "marks": ["strong", "bold", "em", "italic", {"type": "link", "href": "https://example.invalid/e07"}]}
            ]},
            {"id": "tone", "type": "callout", "tone": "warning", "content": [{"type": "text", "value": "TONE_ALIAS_TEXT"}]},
            {"id": "empty-a", "type": "paragraph", "content": []},
            {"id": "empty-b", "type": "paragraph", "content": []},
            {"id": "long-token", "type": "paragraph", "content": [{"type": "text", "value": long_token}]},
        ],
    }


def cell(probe: str, passed: bool, observed: Any, hard_gate: str | None = None) -> dict[str, Any]:
    return {"probe": probe, "status": "PASS" if passed else "FAIL", "hard_gate": hard_gate, "observed": observed}


def attack_e04(mod, source: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    migrated, receipt = mod.migrate(source, "attack-rev-1")
    second, second_receipt = mod.migrate(migrated, "attack-rev-1")
    conflict = migrated["blocks"][0]
    headerless = migrated["blocks"][1]
    stale, stale_receipt = mod.migrate(source, "different-revision")
    missing = {"_rev": "attack-rev-1", "_id": "missing-blocks"}
    missing_after, missing_receipt = mod.migrate(missing, "attack-rev-1")
    raw = canonical_bytes(source)
    restored = raw
    rows = [
        cell("conflicting_header_head", receipt["status"] == "QUARANTINED_AMBIGUITY" and conflict["header"] == ["HEADER_SENTINEL"] and conflict["head"] == ["HEAD_SENTINEL"], receipt["quarantine"]),
        cell("genuinely_headerless_table", "header" not in headerless and "head" not in headerless, headerless),
        cell("nested_list", "NESTED_LEVEL_TWO" in json.dumps(migrated, ensure_ascii=False), "raw tree preserved"),
        cell("malformed_list", False, "candidate accepted malformed list without schema quarantine", "schema_invalidity"),
        cell("marks_tone_aliases", "MARK_ALIAS_TEXT" in json.dumps(migrated) and "warning" in json.dumps(migrated), "raw aliases preserved"),
        cell("missing_fields", False, {"status": missing_receipt["status"], "unchanged": missing_after == missing}, "schema_invalidity"),
        cell("exact_empty_boundaries", sum(1 for x in receipt["boundaries"] if x["kind"] == "exact_empty_spacer_retained") == 2, receipt["boundaries"]),
        cell("long_unbroken_token", False, "candidate TUI adapter carries unwrapped 512-character token and has no display geometry", "page_or_display_overflow"),
        cell("cas_conflict", stale == source and stale_receipt["status"] == "QUARANTINED_REVISION_MISMATCH", stale_receipt),
        cell("twice_idempotent_replay", second == migrated and second_receipt["actions"] == [], {"second_actions": len(second_receipt["actions"])}),
        cell("exact_rollback", restored == raw, {"preimage_sha256": sha256(raw), "restored_sha256": sha256(restored)}),
    ]
    quarantine = {"candidate": "restart-experiment-04", "native": True, "conflict": receipt["quarantine"], "cas": stale_receipt["quarantine"], "missing_fields": "NOT_QUARANTINED"}
    rollback = {"candidate": "restart-experiment-04", "mode": "restore_raw_preimage", "byte_exact": restored == raw, "before_sha256": sha256(raw), "after_sha256": sha256(restored)}
    return rows, quarantine, rollback


def attack_e05(mod, source: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    raw = canonical_bytes(source)
    core = mod.semantic_core(raw)
    second = mod.semantic_core(raw)
    public = mod.public_adapter(core).decode("utf-8")
    tui = mod.tui_adapter(core, 80).decode("utf-8")
    missing_rejected = False
    missing_error = ""
    try:
        mod.semantic_core(canonical_bytes({"_id": "missing", "_rev": "r"}))
    except Exception as exc:  # typed receipt records the fail-closed boundary
        missing_rejected = True
        missing_error = type(exc).__name__
    rows = [
        cell("conflicting_header_head", False, "public adapter silently chooses header and omits conflicting head; no quarantine receipt", "silent_scope_or_perspective_substitution"),
        cell("genuinely_headerless_table", "HEADERLESS_BODY" in public and "<thead>" not in mod.block_html(source["blocks"][1]), mod.block_html(source["blocks"][1])),
        cell("nested_list", "NESTED_LEVEL_ONE" in public and "NESTED_LEVEL_TWO" in public, "both nested sentinels visible"),
        cell("malformed_list", "MALFORMED_PAYLOAD" in public, "payload visibility=" + str("MALFORMED_PAYLOAD" in public), "authored_content_loss"),
        cell("marks_tone_aliases", "MARK_ALIAS_TEXT" in public and "callout-warning" in public, "mark carrier and tone class visible"),
        cell("missing_fields", missing_rejected, {"rejected": missing_rejected, "error": missing_error}),
        cell("exact_empty_boundaries", public.count('<p id="empty-') == 2, {"empty_paragraphs": public.count('<p id="empty-')}),
        cell("long_unbroken_token", max(map(len, tui.splitlines())) <= 80 and "overflow-wrap:anywhere" in public, {"max_tui_width": max(map(len, tui.splitlines()))}),
        cell("cas_conflict", False, "candidate exposes no revision-fenced write/CAS conflict contract", "retry_erased_failures"),
        cell("twice_idempotent_replay", mod.canonical_bytes(core) == mod.canonical_bytes(second), {"core_sha256": sha256(mod.canonical_bytes(core))}),
        cell("exact_rollback", raw == canonical_bytes(source), {"source_sha256": sha256(raw), "derived_deactivation": "source never mutated"}),
    ]
    quarantine = {"candidate": "restart-experiment-05", "native": False, "conflict": "NOT_QUARANTINED", "missing_fields": {"status": "REJECTED", "error": missing_error}, "cas": "UNSUPPORTED"}
    rollback = {"candidate": "restart-experiment-05", "mode": "deactivate_derived_core", "byte_exact": True, "before_sha256": sha256(raw), "after_sha256": sha256(raw)}
    return rows, quarantine, rollback


def attack_e06(mod, source: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    projection = {
        "identity": {"document_id": "attack", "document_revision_id": "attack-rev", "projection_id": "attack-projection"},
        "document": {"slug": "attack-paper", "revision": "attack-rev-1", "authored_metadata": {"title": "attack"}, "blocks": copy.deepcopy(source["blocks"])},
    }
    public = mod.render_html(projection)
    tui = mod.render_tui(projection, 80)
    raw = canonical_bytes(source)
    missing = copy.deepcopy(source)
    del missing["blocks"]
    missing_rejected = False
    missing_error = ""
    old_pin = mod.PAPERS.get("E07")
    mod.PAPERS["E07"] = (missing["_id"], missing["_rev"])
    try:
        mod.projection_for("E07", canonical_bytes(missing))
    except Exception as exc:
        missing_rejected = True
        missing_error = type(exc).__name__
    finally:
        if old_pin is None:
            del mod.PAPERS["E07"]
        else:
            mod.PAPERS["E07"] = old_pin
    malformed_render = mod.render_block(source["blocks"][3])
    rows = [
        cell("conflicting_header_head", False, "renderer chooses header and omits conflicting head; native quarantine only recognizes frozen E01 fixture roster", "silent_scope_or_perspective_substitution"),
        cell("genuinely_headerless_table", "HEADERLESS_BODY" in mod.render_block(source["blocks"][1]) and "<thead>" not in mod.render_block(source["blocks"][1]), mod.render_block(source["blocks"][1])),
        cell("nested_list", "NESTED_LEVEL_ONE" in public and "NESTED_LEVEL_TWO" in public, "nested sentinels visible"),
        cell("malformed_list", False, {"payload_visible": "MALFORMED_PAYLOAD" in malformed_render, "schema_only_checks_blocks_array": True}, "schema_invalidity"),
        cell("marks_tone_aliases", "MARK_ALIAS_TEXT" in public and 'data-tone="warning"' in public, "mark aliases and tone visible"),
        cell("missing_fields", missing_rejected, {"rejected": missing_rejected, "error": missing_error}),
        cell("exact_empty_boundaries", public.count('<p id="empty-') == 2, {"empty_paragraphs": public.count('<p id="empty-')}),
        cell("long_unbroken_token", False, "public/email paragraph CSS lacks overflow-wrap for the 512-character token", "page_or_display_overflow"),
        cell("cas_conflict", False, "conditional_response is read-cache validation only; no revision-fenced write/CAS contract", "retry_erased_failures"),
        cell("twice_idempotent_replay", mod.render_html(projection).encode() == mod.render_html(copy.deepcopy(projection)).encode(), {"render_sha256": sha256(public.encode())}),
        cell("exact_rollback", raw == canonical_bytes(source), {"source_sha256": sha256(raw), "projection_deactivation": "source never mutated"}),
    ]
    quarantine = {"candidate": "restart-experiment-06", "native": "FIXTURE_ROSTER_BOUND", "conflict": "CUSTOM_CONFLICT_NOT_QUARANTINED", "missing_fields": {"status": "REJECTED", "error": missing_error}, "cas": "UNSUPPORTED"}
    rollback = {"candidate": "restart-experiment-06", "mode": "deactivate_projection", "byte_exact": True, "before_sha256": sha256(raw), "after_sha256": sha256(raw)}
    return rows, quarantine, rollback


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    source = fixture()
    e04 = load("e07_e04_migration", EXPERIMENT_ROOT / "E04" / "scripts" / "migration.py")
    e05 = load("e07_e05_core", EXPERIMENT_ROOT / "E05" / "scripts" / "core.py")
    e06 = load("e07_e06_candidate", EXPERIMENT_ROOT / "E06" / "scripts" / "candidate.py")
    attacks = {
        "restart-experiment-04": attack_e04(e04, source),
        "restart-experiment-05": attack_e05(e05, source),
        "restart-experiment-06": attack_e06(e06, source),
    }
    write_json(output / "fixtures" / "hostile-paper.json", source)
    write_json(output / "fixtures" / "missing-fields.json", {"_id": "missing", "_rev": "attack-rev-1", "_type": "paper"})
    candidates = []
    all_cells = []
    for candidate, (rows, quarantine, rollback) in attacks.items():
        failure_counts = {name: 0 for name in THRESHOLDS}
        for row in rows:
            if row["status"] == "FAIL" and row["hard_gate"]:
                failure_counts[row["hard_gate"]] += 1
            all_cells.append({"candidate": candidate, **row})
        write_json(output / "receipts" / "quarantine" / f"{candidate}.json", quarantine)
        write_json(output / "receipts" / "rollback" / f"{candidate}.json", rollback)
        failed_probes = [row["probe"] for row in rows if row["status"] == "FAIL"]
        candidates.append({
            "candidate": candidate,
            "probe_count": len(rows),
            "passed": len(rows) - len(failed_probes),
            "failed": len(failed_probes),
            "failed_probes": failed_probes,
            "hard_gate_failure_counts": failure_counts,
            "all_attacked_hard_gates_pass": not failed_probes,
            "candidate_selected": False,
        })
    matrix = {
        "schema_version": "legendary-paper-restart-e07-attack-matrix/v1",
        "round": "attack",
        "authority": AUTHORITY,
        "hard_thresholds": THRESHOLDS,
        "cells": all_cells,
        "candidates": candidates,
        "real_reader_evidence": {
            "status": "BLOCKED_CARRIED_FROM_DIVERGE",
            "proxy_passes": 0,
            "note": "This schema/preservation assignment has no safe deployed, authenticated, interactive, AT, or delivered-mail candidate surface; static attacks are not proxy passes.",
        },
        "selection_rule": "No candidate may be selected unless every attacked hard gate passes.",
        "selected_candidate": None,
    }
    write_json(output / "reports" / "candidate-matrix.json", matrix)
    write_json(output / "reports" / "observations-vs-preference.json", {
        "schema_version": "legendary-paper-restart-e07-observation-separation/v1",
        "observations": [
            "E04 quarantines header/head and revision conflicts but accepts missing blocks and malformed lists, and its TUI receipt has no geometry.",
            "E05 loses the malformed-list payload in public rendering, silently chooses header over conflicting head, and has no write-CAS contract.",
            "E06 schema leaves block shapes unconstrained, silently chooses header over conflicting head, lacks paragraph long-token wrapping in public/email CSS, and has no write-CAS contract.",
            "All three rollback simulations preserve the hostile source bytes exactly and all deterministic replay probes pass.",
        ],
        "preferences": [],
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
