#!/usr/bin/env python3
"""Derive deterministic hard-gate reports from the frozen E02 capture."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs"
PROFILES = ("desktop", "390", "320", "reflow200")
HUMAN_SURFACES = ("public", "email")


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value) + b"\n")


def text_of(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return " ".join(text_of(item) for item in value)
    if isinstance(value, dict):
        keys = ("text", "value", "content", "children", "items", "header", "head", "rows", "body")
        return " ".join(text_of(value.get(key, "")) for key in keys)
    return ""


def tokens(value):
    return re.findall(r"[^\W_]+", value.casefold(), flags=re.UNICODE)


def ordered_projection(blocks, body_text):
    haystack = tokens(body_text)
    cursor = 0
    passed = 0
    failures = []
    for ordinal, block in enumerate(blocks):
        needle = tokens(text_of(block))
        if not needle:
            continue
        probe = cursor
        first = None
        for wanted in needle:
            while probe < len(haystack) and haystack[probe] != wanted:
                probe += 1
            if probe >= len(haystack):
                failures.append({"ordinal": ordinal, "block_id": block.get("id"), "token_count": len(needle), "first_missing_token": wanted})
                break
            if first is None:
                first = probe
            probe += 1
        else:
            passed += 1
            cursor = probe
    total = sum(bool(tokens(text_of(block))) for block in blocks)
    return {"passed": passed, "total": total, "failures": failures, "ordered": not failures}


def source_metrics(blocks):
    metrics = {"blocks": len(blocks), "nonempty_carriers": 0, "empty_paragraphs": 0, "tables": 0, "headerless_tables": 0, "header_cells": 0, "body_cells": 0, "callouts": 0, "mark_records": 0}
    ids = []
    for block in blocks:
        ids.append(block.get("id"))
        if tokens(text_of(block)):
            metrics["nonempty_carriers"] += 1
        if block.get("type") == "paragraph" and not tokens(text_of(block)):
            metrics["empty_paragraphs"] += 1
        if block.get("type") == "table":
            metrics["tables"] += 1
            header = block.get("header", block.get("head", []))
            rows = block.get("rows", block.get("body", []))
            if not isinstance(header, list) or not header:
                metrics["headerless_tables"] += 1
            else:
                metrics["header_cells"] += len(header)
            if isinstance(rows, list):
                metrics["body_cells"] += sum(len(row) if isinstance(row, list) else 1 for row in rows)
        if block.get("type") == "callout":
            metrics["callouts"] += 1
        stack = [block]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                if isinstance(node.get("marks"), list):
                    metrics["mark_records"] += len(node["marks"])
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
    metrics["ids_unique_nonblank"] = len(ids) == len(set(ids)) and all(isinstance(item, str) and item for item in ids)
    return metrics


def gate(gate_id, status, passed, total, threshold, evidence, observation):
    return {"id": gate_id, "status": status, "passed": passed, "total": total, "threshold": threshold, "evidence": evidence, "observation": observation}


def main():
    capture = json.loads((OUT / "raw-capture-manifest.json").read_bytes())
    paper_metrics = {}
    projections = []
    geometry = []
    semantics = []
    focus = []
    studio = []
    for paper in capture["papers"]:
        blocks = json.loads((ROOT / paper["http"]["source"]["path"]).read_bytes())["source"]["blocks"]
        metrics = source_metrics(blocks)
        paper_metrics[paper["short_id"]] = metrics
        for surface in HUMAN_SURFACES:
            for profile in PROFILES:
                cell = paper["browser"][surface][profile]
                projection = ordered_projection(blocks, cell["bodyText"])
                projections.append({"paper": paper["short_id"], "surface": surface, "profile": profile, **projection})
                geometry.append({
                    "paper": paper["short_id"], "surface": surface, "profile": profile,
                    "overflow": cell["horizontalOverflow"], "control_overlap_count": len(cell["controlOverlaps"]),
                    "document_scroll_width": cell["document"]["scrollWidth"], "client_width": cell["viewport"]["clientWidth"],
                })
                expected_tables = metrics["tables"]
                expected_callouts = metrics["callouts"]
                expected_marks = metrics["mark_records"]
                observed_tables = cell["tables"]
                table_semantic = len(observed_tables) == expected_tables and all(
                    table.get("role") != "presentation" and (metrics["headerless_tables"] == expected_tables or table["headers"] > 0)
                    for table in observed_tables
                )
                callout_semantic = len(cell["callouts"]) >= expected_callouts and all(item.get("role") or item.get("label") or item.get("tag") == "ASIDE" for item in cell["callouts"][:expected_callouts])
                observed_marks = sum(cell["semanticMarks"].values())
                semantics.append({
                    "paper": paper["short_id"], "surface": surface, "profile": profile,
                    "expected_tables": expected_tables, "observed_tables": len(observed_tables), "table_semantic": table_semantic,
                    "expected_callouts": expected_callouts, "observed_callouts": len(cell["callouts"]), "callout_semantic": callout_semantic,
                    "expected_mark_records": expected_marks, "observed_semantic_mark_elements": observed_marks, "marks_semantic": observed_marks >= expected_marks,
                })
                interactive = cell["controlCount"] > 0
                focus_ok = (not interactive) or (bool(cell["focusOrder"]) and all(item["focusVisible"] for item in cell["focusOrder"]) and cell["positiveTabindex"] == 0)
                focus.append({"paper": paper["short_id"], "surface": surface, "profile": profile, "interactive": interactive, "control_count": cell["controlCount"], "focus_events": len(cell["focusOrder"]), "focus_visible_and_dom_order": focus_ok, "positive_tabindex": cell["positiveTabindex"]})
        for profile in PROFILES:
            cell = paper["browser"]["studio"][profile]
            studio.append({"paper": paper["short_id"], "profile": profile, "requested_url": cell["requestedUrl"], "final_url": cell["url"], "auth_gate": cell["authGate"], "title": cell["title"], "login_focus_events_observation": len(cell["focusOrder"]), "session_cookie_metadata": cell["sessionCookieMetadata"]})

    totals = {key: sum(metrics[key] for metrics in paper_metrics.values()) for key in next(iter(paper_metrics.values())) if isinstance(next(iter(paper_metrics.values()))[key], int)}
    pins = sum(paper["pin_match"] and paper["block_count_match"] and paper["projection_match"] for paper in capture["papers"])
    carrier_total = sum(item["total"] for item in projections)
    carrier_pass = sum(item["passed"] for item in projections)
    order_pass = sum(item["ordered"] for item in projections)
    overflow_pass = sum(not item["overflow"] for item in geometry)
    overlap_pass = sum(item["control_overlap_count"] == 0 for item in geometry)
    focus_pass = sum(item["focus_visible_and_dom_order"] for item in focus)
    table_pass = sum(item["table_semantic"] for item in semantics)
    callout_pass = sum(item["callout_semantic"] for item in semantics)
    mark_pass = sum(item["marks_semantic"] for item in semantics)
    studio_blocked = sum(item["auth_gate"] for item in studio)
    email_mime_pass = sum("text/html" in paper["http"]["email"]["safe_headers"].get("content-type", "").lower() for paper in capture["papers"])
    gates = [
        gate("frozen_source_and_cli", "PASS" if pins == 4 else "FAIL", pins, 4, "4/4 exact pins, block counts, and canonical CLI projections", "outputs/raw-capture-manifest.json", "Read-only source and bp -s guerrilla captures."),
        gate("authored_carrier_survival", "PASS" if carrier_pass == carrier_total else "FAIL", carrier_pass, carrier_total, "100% ordered nonempty authored carriers across public/email x four profiles", "outputs/semantic-order.json", f"{carrier_total-carrier_pass} carrier projections are missing or out of order."),
        gate("reading_order", "PASS" if order_pass == 32 else "FAIL", order_pass, 32, "32/32 public/email reader-profile cells preserve source block order", "outputs/semantic-order.json", "Greedy token-order comparison advances monotonically through reader-visible text."),
        gate("page_overflow", "PASS" if overflow_pass == 32 else "FAIL", overflow_pass, 32, "32/32 public/email cells have scrollWidth <= clientWidth", "outputs/geometry.json", f"{32-overflow_pass} cells overflow horizontally."),
        gate("control_overlap", "PASS" if overlap_pass == 32 else "FAIL", overlap_pass, 32, "32/32 public/email cells have zero visible control intersections >4px in both axes", "outputs/geometry.json", f"{32-overlap_pass} cells contain overlapping controls."),
        gate("focus_order", "PASS" if focus_pass == 32 else "FAIL", focus_pass, 32, "32/32 public/email cells have DOM-order Tab traversal, visible focus, and no positive tabindex", "outputs/focus.json", "Static cells with no controls are non-interactive; browser Tab events are not AT proof."),
        gate("data_table_semantics", "PASS" if table_pass == 32 else "FAIL", table_pass, 32, "32/32 cells preserve table count and non-presentational header semantics without inventing headers", "outputs/semantics.json", f"Source contains {totals['tables']} tables, {totals['headerless_tables']} intentionally headerless, {totals['header_cells']} authored header cells, and {totals['body_cells']} body cells."),
        gate("callout_semantics", "PASS" if callout_pass == 32 else "FAIL", callout_pass, 32, "32/32 cells preserve callout count and semantic label/role", "outputs/semantics.json", f"Source contains {totals['callouts']} callouts."),
        gate("authored_mark_semantics", "PASS" if mark_pass == 32 else "FAIL", mark_pass, 32, "32/32 cells expose at least the authored semantic mark-record count", "outputs/semantics.json", f"Source contains {totals['mark_records']} authored mark records."),
        gate("email_preview_mime", "PASS" if email_mime_pass == 4 else "FAIL", email_mime_pass, 4, "4/4 HTTP previews declare text/html", "outputs/raw-capture-manifest.json", "This proves only HTTP preview MIME, not delivered multipart email."),
        gate("authenticated_studio", "BLOCKED", 0, 16, "16/16 exact-paper Studio cells at desktop/390/320/reflow200", "outputs/unavailable-clients.json", f"All {studio_blocked}/16 anonymous fresh-profile navigations reached the login gate; no authenticated session was supplied."),
        gate("real_assistive_technology", "BLOCKED", 0, 48, "48/48 public/Studio/email reader-profile cells exercised with VoiceOver/NVDA or equivalent", "outputs/unavailable-clients.json", "CDP accessibility trees are retained as browser observations and never counted as AT proof."),
        gate("delivered_mail_clients", "BLOCKED", 0, 48, "48/48 four Papers x four profiles x Gmail/Outlook/Apple Mail", "outputs/unavailable-clients.json", "No delivery account or real mail-client session was available."),
        gate("studio_authored_loss_geometry_focus", "BLOCKED", 0, 16, "16/16 authenticated Studio cells satisfy loss/overflow/overlap/order/focus/session/reconnect gates", "outputs/unavailable-clients.json", "The login reader is observable, but it cannot proxy the requested Paper pane."),
    ]
    write_json(OUT / "source-denominators.json", {"schema_version": "legendary-restart-e02-denominators/v1", "papers": paper_metrics, "totals": totals})
    write_json(OUT / "semantic-order.json", {"schema_version": "legendary-restart-e02-semantic-order/v1", "cells": projections, "summary": {"passed_carriers": carrier_pass, "total_carriers": carrier_total, "ordered_cells": order_pass, "total_cells": 32}})
    write_json(OUT / "geometry.json", {"schema_version": "legendary-restart-e02-geometry/v1", "cells": geometry, "summary": {"overflow_pass": overflow_pass, "control_overlap_pass": overlap_pass, "total_cells": 32}})
    write_json(OUT / "focus.json", {"schema_version": "legendary-restart-e02-focus/v1", "cells": focus, "summary": {"pass": focus_pass, "total": 32}, "scope_note": "Real CDP Tab events; not assistive-technology proof."})
    write_json(OUT / "semantics.json", {"schema_version": "legendary-restart-e02-semantics/v1", "cells": semantics, "source_totals": totals, "summary": {"table_cells_pass": table_pass, "callout_cells_pass": callout_pass, "mark_cells_pass": mark_pass, "total_cells": 32}})
    unavailable = {
        "schema_version": "legendary-restart-e02-unavailable/v1", "studio": studio,
        "blocked": [
            {"client": "authenticated Studio Paper pane", "passed": 0, "total": 16, "reason": "Fresh anonymous profiles reached login; no credential or session supplied."},
            {"client": "real assistive technology", "passed": 0, "total": 48, "reason": "No VoiceOver/NVDA-equivalent session available."},
            {"client": "delivered mail clients", "passed": 0, "total": 48, "reason": "No Gmail/Outlook/Apple Mail delivery account or session available."},
        ],
    }
    write_json(OUT / "unavailable-clients.json", unavailable)
    summary = {status: sum(item["status"] == status for item in gates) for status in ("PASS", "FAIL", "BLOCKED")}
    write_json(OUT / "scorecard.json", {"schema_version": "legendary-restart-e02-scorecard/v1", "hard_policy": "Any FAIL or BLOCKED prevents a baseline pass; no missing client is a proxy pass.", "gates": gates, "summary": summary})
    failures = [
        {"gate": item["id"], "status": item["status"], "passed": item["passed"], "total": item["total"], "observation": item["observation"]}
        for item in gates if item["status"] != "PASS"
    ]
    write_json(OUT / "failure-taxonomy.json", {"schema_version": "legendary-restart-e02-failures/v1", "hard_failures_and_blocks": failures})
    observed = [
        f"Frozen pins/block counts/CLI projection pass {pins}/4.",
        f"Ordered authored-carrier projections pass {carrier_pass}/{carrier_total}; ordered reader cells pass {order_pass}/32.",
        f"No-overflow cells pass {overflow_pass}/32; no-control-overlap cells pass {overlap_pass}/32; focus cells pass {focus_pass}/32.",
        f"Source denominators are {totals['blocks']} blocks, {totals['header_cells']} header cells, {totals['body_cells']} table body cells, {totals['mark_records']} mark records, and {totals['headerless_tables']} headerless tables.",
        f"Authenticated Studio is blocked 16/16 by login; actual AT 48/48 and delivered mail clients 48/48 are unavailable.",
    ]
    inferences = [
        "The current human-reader baseline is not eligible to pass because at least one hard failure or blocked target surface remains.",
        "HTTP email preview, login-page geometry, and CDP accessibility trees constrain implementation work but cannot establish delivered-email, authenticated-Studio, or assistive-technology parity.",
    ]
    result = {
        "schema_version": "barkpark-cycle-experiment-result/v1", "assignment_id": "restart-experiment-02", "assignment_uuid": "d75c84e3-5f21-4830-818a-ce2b3f519b2a",
        "agent_type": "legendary-experimenter", "effort": "medium", "round": "baseline", "epic_task_id": "task-a768c69e659add58",
        "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart", "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
        "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc", "candidate_ids": [],
        "verdict": "BASELINE_FAIL_WITH_BLOCKED_SURFACES", "score_summary": summary, "threshold_results": gates,
        "denominators": totals, "observations": observed, "inferences": inferences,
        "risks": [item["observation"] for item in gates if item["status"] in ("FAIL", "BLOCKED")],
        "evidence_paths": ["outputs/raw-capture-manifest.json", "outputs/redacted-capture-manifest.json", "outputs/source-denominators.json", "outputs/semantic-order.json", "outputs/geometry.json", "outputs/focus.json", "outputs/semantics.json", "outputs/unavailable-clients.json", "outputs/scorecard.json", "outputs/failure-taxonomy.json", "outputs/timing.json"],
        "reproducibility": {"capture": "BARKPARK_MANIFEST=docs/cli/fixtures/full-manifest.json python3 scripts/capture.py", "report": "python3 scripts/build_report.py", "verify_twice": "python3 scripts/verify.py && python3 scripts/verify.py"},
        "production_mutated": False, "paper_mutated": False, "task_mutated": False, "cycle_mutated": False,
    }
    write_json(ROOT / "result.json", result)
    cycle_handoff = {"assignment_id": "restart-experiment-02", "assignment_uuid": "d75c84e3-5f21-4830-818a-ce2b3f519b2a", "agent_type": "legendary-experimenter", "round": "baseline", "status": "completed", "verdict": result["verdict"], "evidence": ".omx/state/legendary-paper-reader-upgrade-restart-experiments/E02/result.json"}
    (ROOT / "cycle-handoff.json").write_bytes(canonical(cycle_handoff) + b"\n")


if __name__ == "__main__":
    main()
