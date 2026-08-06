#!/usr/bin/env python3
"""Derive the frozen baseline scorecard, fixtures, taxonomy, and result."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from lxml import html

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs"
FIX = ROOT / "fixtures"


def canon(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def sha(data): return hashlib.sha256(data).hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canon(value) + b"\n")


def text_of(value):
    if isinstance(value, str): return value
    if isinstance(value, list): return " ".join(text_of(v) for v in value)
    if isinstance(value, dict):
        return " ".join(filter(None, [str(value.get("text", "")), str(value.get("value", "")), text_of(value.get("content", [])), text_of(value.get("children", [])), text_of(value.get("items", [])), text_of(value.get("header", [])), text_of(value.get("head", [])), text_of(value.get("rows", [])), text_of(value.get("body", []))]))
    return ""


def norm(value): return re.sub(r"\s+", " ", value).strip()


def tokens(value): return re.findall(r"[^\W_]+", value.casefold(), flags=re.UNICODE)


def is_subsequence(needle, haystack):
    cursor = iter(haystack)
    return all(any(candidate == wanted for candidate in cursor) for wanted in needle)


def check_public_text(short):
    source = json.loads((ROOT / "raw" / short / "source.json").read_bytes())["source"]["blocks"]
    tree = html.fromstring((ROOT / "raw" / short / "public.html").read_bytes())
    nodes = {e.get("data-block-id"): norm(" ".join(e.itertext())) for e in tree.xpath("//*[@data-block-id]")}
    mismatches = []
    for block in source:
        block_id = block.get("id")
        expected = norm(text_of(block))
        actual = nodes.get(block_id)
        if actual is None or (expected and not is_subsequence(tokens(expected), tokens(actual))):
            mismatches.append({"block_id": block_id, "expected_chars": len(expected), "actual_chars": len(actual or ""), "missing_wrapper": actual is None})
    return {"source_blocks": len(source), "public_wrappers": len(nodes), "mismatch_count": len(mismatches), "mismatches": mismatches}


def gate(gate_id, status, passed, total, threshold, evidence, note):
    return {"id": gate_id, "status": status, "passed": passed, "total": total, "threshold": threshold, "evidence": evidence, "observation": note}


def main():
    capture = json.loads((OUT / "capture-manifest.json").read_bytes())
    fixtures = {
        "long_token": {"type": "paragraph", "id": "adv-long-token", "content": [{"type": "text", "value": "https://example.invalid/" + "A" * 512}]},
        "nested_table_callout": {"type": "callout", "id": "adv-nested-callout", "tone": "warning", "content": [{"type": "table", "id": "adv-table", "header": ["Name", "Status", "Evidence"], "rows": [["nested", "blocked", "x" * 160], ["second", "ready", "short"]]}]},
        "nested_list": {"type": "list", "id": "adv-nested-list", "style": "unordered", "items": [[{"type": "paragraph", "content": [{"type": "text", "value": "wrapped item"}]}], {"type": "list", "items": ["level two", ["level three"]]}]},
        "marked_focus": {"type": "paragraph", "id": "adv-marks", "content": [{"type": "text", "value": "strong", "marks": ["strong"]}, {"type": "text", "value": "code", "marks": ["code"]}, {"type": "link", "href": "https://example.invalid/focus", "content": [{"type": "text", "value": "focus target"}]}]},
        "phone_chrome": {"viewports": [{"width": 320, "height": 568}, {"width": 390, "height": 844}], "safe_area_insets": {"top": 47, "right": 0, "bottom": 34, "left": 0}, "browser_chrome_px": {"top": 54, "bottom": 44}},
        "long_document": {"blocks": [{"type": "heading", "level": 2, "id": f"adv-h-{i}", "content": [{"type": "text", "value": f"Section {i}"}]}, {"type": "paragraph", "id": f"adv-p-{i}", "content": [{"type": "text", "value": ("long paragraph " * 80).strip()}]}] for i in range(1, 41)},
    }
    fixture_entries = []
    for name, value in fixtures.items():
        path = FIX / f"{name}.json"; write(path, value)
        fixture_entries.append({"id": name, "path": str(path.relative_to(ROOT)), "sha256": sha(path.read_bytes())})
    write(ROOT / "fixture-manifest.json", {"schema_version": "legendary-e02-adversarial/v1", "count": len(fixture_entries), "fixtures": fixture_entries, "reader_exercise_status": "BLOCKED_NOT_INGESTED", "reason": "Round-1 baseline is read-only and no repair candidate exists; fixture presence is not a reader pass."})

    text_checks = {p["short_id"]: check_public_text(p["short_id"]) for p in capture["papers"]}
    total_blocks = sum(v["source_blocks"] for v in text_checks.values())
    text_mismatches = sum(v["mismatch_count"] for v in text_checks.values())
    total_tables = sum(p["source_metrics"]["types"].get("table", 0) for p in capture["papers"])
    total_callouts = sum(p["source_metrics"]["callouts"] for p in capture["papers"])
    total_marks = sum(p["source_metrics"]["marked_nodes"] for p in capture["papers"])
    spacers = sum(p["source_metrics"]["empty_paragraphs"] for p in capture["papers"])
    public_cells = [p["browser"]["public"][str(w)] for p in capture["papers"] for w in (320, 390)]
    email_cells = [p["browser"]["email"][str(w)] for p in capture["papers"] for w in (320, 390)]
    public_geometry_pass = sum(not c["horizontalOverflow"] for c in public_cells)
    email_geometry_pass = sum((not c["horizontalOverflow"]) and c["viewport"]["clientWidth"] in (320, 390) for c in email_cells)
    public_landmarks_pass = sum(c["landmarks"]["main"] == 1 and c["landmarks"]["article"] == 1 and c["landmarks"]["h1"] == 1 and bool(c["landmarks"]["lang"]) for c in public_cells)
    keyboard_pass = sum(bool(c["keyboard_focus_order"]) and all(x["focusVisible"] for x in c["keyboard_focus_order"]) for c in public_cells)
    pin_pass = sum(p["pin_match"] for p in capture["papers"])
    projection_pass = sum(p["projection_match"] for p in capture["papers"])
    id_pass = sum(p["source_metrics"]["ids_unique_nonblank"] for p in capture["papers"])
    gates = [
        gate("exact_revision_pins", "PASS" if pin_pass == 4 else "FAIL", pin_pass * 2, 8, "8/8 source+CLI revision identities", "outputs/capture-manifest.json", "Both source and CLI projections match all four assigned pins."),
        gate("source_cli_semantic_hash", "PASS" if projection_pass == 4 else "FAIL", projection_pass, 4, "4/4 canonical block hashes", "outputs/capture-manifest.json", "Canonical source and broad CLI block projections agree."),
        gate("unique_block_identity", "PASS" if id_pass == 4 else "FAIL", id_pass, 4, "4/4 Papers", "outputs/capture-manifest.json", "All source block IDs are nonblank and unique."),
        gate("public_visible_text", "PASS" if text_mismatches == 0 else "FAIL", total_blocks - text_mismatches, total_blocks, "100%; zero silent losses", "outputs/text-parity.json", f"{text_mismatches} source blocks lack their normalized authored text in public HTML."),
        gate("empty_spacer_quality", "FAIL", 0, 4, "4/4 Papers contain zero empty paragraph spacers", "outputs/capture-manifest.json", f"All four Papers fail; {spacers} empty spacers total."),
        gate("public_320_390_geometry", "PASS" if public_geometry_pass == 8 else "FAIL", public_geometry_pass, 8, "8/8 cells without document overflow", "outputs/capture-manifest.json", "Real headless-Chrome device metrics; transient HTTP 500 attempts are retained."),
        gate("email_320_390_geometry", "PASS" if email_geometry_pass == 8 else "FAIL", email_geometry_pass, 8, "8/8 cells honor requested viewport and do not overflow", "outputs/capture-manifest.json", "HTTP email preview is not a real mail client; missing viewport handling and overflow count as failures."),
        gate("public_landmarks", "PASS" if public_landmarks_pass == 8 else "FAIL", public_landmarks_pass, 8, "8/8 main+article+h1+lang", "outputs/capture-manifest.json", "Browser DOM landmark count."),
        gate("table_accessibility", "FAIL", 0, total_tables, f"{total_tables}/{total_tables} data tables retain scoped headers/caption and non-presentational semantics", "outputs/capture-manifest.json", "Captured public tables use role=presentation and have zero scoped headers/captions."),
        gate("callout_accessibility", "FAIL", 0, total_callouts, f"{total_callouts}/{total_callouts} callouts carry semantic role and accessible tone label", "outputs/capture-manifest.json", "Captured callouts are unlabeled generic divs."),
        gate("authored_marks", "FAIL", 0, total_marks, f"{total_marks}/{total_marks} authored marked nodes retain matching semantics", "outputs/capture-manifest.json", "String-valued strong/code marks are not preserved as a one-to-one semantic projection."),
        gate("keyboard_focus", "PASS" if keyboard_pass == 8 else "FAIL", keyboard_pass, 8, "8/8 public width cells have keyboard-reachable focus-visible targets", "outputs/capture-manifest.json", "Actual CDP Tab events and :focus-visible state; this does not substitute for AT."),
        gate("revision_identity_in_reader", "FAIL", 0, 16, "16/16 public+email width cells expose exact immutable revision identity", "outputs/capture-manifest.json", "Public article exposes stream data-rev=0; email exposes no source revision."),
        gate("authenticated_studio", "BLOCKED", 0, 8, "8/8 exact-pin Studio cells at 320/390", "outputs/gaps.json", "No authenticated, revision-bound Studio browser session was available in this assignment."),
        gate("real_assistive_technology", "BLOCKED", 0, 8, "8/8 public width cells in VoiceOver/NVDA or equivalent", "outputs/gaps.json", "Browser AX trees were captured but are not counted as real AT proof."),
        gate("real_mail_clients", "BLOCKED", 0, 24, "24/24: four Papers x two widths x Gmail/Outlook/Apple Mail", "outputs/gaps.json", "Only the deterministic HTTP email preview exists; it is not a delivered mail-client artifact."),
        gate("adversarial_reader_execution", "BLOCKED", 0, len(fixture_entries), f"{len(fixture_entries)}/{len(fixture_entries)} fixtures exercised in each declared reader", "fixture-manifest.json", "Fixtures are frozen and hashed; read-only baseline cannot ingest them without a candidate or production mutation."),
    ]
    write(OUT / "text-parity.json", text_checks)
    write(OUT / "threshold-scorecard.json", {"schema_version": "legendary-e02-thresholds/v1", "hard_policy": "Any FAIL or BLOCKED prevents baseline acceptance as reader-safe; scores never average away hard failures.", "gates": gates, "summary": {s: sum(g["status"] == s for g in gates) for s in ("PASS", "FAIL", "BLOCKED")}})
    failures = [
        {"code": "F-STRUCT-EMPTY-SPACER", "class": "structural_completeness", "severity": "high", "affected": "4/4 Papers", "count": spacers},
        {"code": "F-TEXT-SILENT-LOSS", "class": "reader_visibility", "severity": "critical", "affected": f"{text_mismatches}/{total_blocks} public blocks", "count": text_mismatches},
        {"code": "F-GEOM-PUBLIC", "class": "responsive_geometry", "severity": "high", "affected": f"{8-public_geometry_pass}/8 public cells", "count": 8-public_geometry_pass},
        {"code": "F-GEOM-EMAIL", "class": "responsive_geometry", "severity": "high", "affected": f"{8-email_geometry_pass}/8 email-preview cells", "count": 8-email_geometry_pass},
        {"code": "F-A11Y-TABLE", "class": "accessibility_semantics", "severity": "high", "affected": f"{total_tables}/{total_tables} tables", "count": total_tables},
        {"code": "F-A11Y-CALLOUT", "class": "accessibility_semantics", "severity": "high", "affected": f"{total_callouts}/{total_callouts} callouts", "count": total_callouts},
        {"code": "F-MARK-FLATTEN", "class": "semantic_contract", "severity": "high", "affected": f"{total_marks} authored marked nodes", "count": total_marks},
        {"code": "F-REV-UNBOUND", "class": "revision_identity", "severity": "high", "affected": "16/16 browser cells", "count": 16},
        {"code": "F-HTTP-TRANSIENT-500", "class": "reader_reliability", "severity": "carried", "affected": "3 pre-final browser cells; 0/16 on immediate final repeat", "count": 3},
        {"code": "B-STUDIO-AUTH", "class": "capability_block", "severity": "blocked", "affected": "8/8 Studio cells", "count": 8},
        {"code": "B-REAL-AT", "class": "capability_block", "severity": "blocked", "affected": "8/8 AT cells", "count": 8},
        {"code": "B-REAL-MAIL", "class": "capability_block", "severity": "blocked", "affected": "24/24 mail-client cells", "count": 24},
    ]
    write(OUT / "failure-taxonomy.json", {"schema_version": "legendary-e02-failures/v1", "failures": failures})
    gaps = {"blocked": [f for f in failures if f["severity"] == "blocked"], "carried_risks": ["Intermittent deployed HTTP 500s occurred during browser geometry retries and are retained in navigation_attempts.", "Email route is an HTML preview, not multipart/delivered mail.", "Browser AX-tree roles are observations, not an AT pass.", "Adversarial fixtures are frozen but not reader-exercised in this read-only baseline."]}
    write(OUT / "gaps.json", gaps)
    surface = {
        "public": {"real_reader": True, "cells": 8, "geometry_pass": public_geometry_pass, "landmark_pass": public_landmarks_pass, "status": "FAIL"},
        "studio": {"real_reader": False, "cells": 8, "passed": 0, "status": "BLOCKED"},
        "email_http_preview": {"real_reader": True, "real_mail_client": False, "cells": 8, "geometry_pass": email_geometry_pass, "status": "FAIL"},
        "cli_api": {"real_reader": True, "cells": 8, "revision_pass": pin_pass * 2, "semantic_hash_pass": projection_pass * 2, "status": "PASS_FOR_IDENTITY_ONLY"},
        "shared_semantic_contracts": {"papers": 4, "unique_id_pass": id_pass, "text_blocks": total_blocks, "text_mismatches": text_mismatches, "tables": total_tables, "callouts": total_callouts, "marks": total_marks, "status": "FAIL"},
    }
    write(OUT / "surface-matrix.json", surface)
    observations = [
        f"All 8 source/CLI revision identity checks match the exact assigned pins; all 4 canonical block hashes agree.",
        f"The four sources contain {total_blocks} blocks and {spacers} empty paragraph spacers; all 4 fail the zero-spacer threshold.",
        f"Public normalized block-text parity is {total_blocks-text_mismatches}/{total_blocks}; {text_mismatches} blocks fail.",
        f"Public geometry passes {public_geometry_pass}/8 320/390 cells; email-preview geometry passes {email_geometry_pass}/8.",
        f"All {total_tables} data tables lack the frozen accessibility contract; all {total_callouts} callouts lack semantic labels.",
        f"CDP browser AX trees and Tab focus evidence are captured, but no real AT or mail client was exercised.",
    ]
    result = {
        "schema_version": "barkpark-cycle-experiment-result/v1", "assignment_id": "experiment-02", "round": 1,
        "epic_task_id": "task-a768c69e659add58", "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-05",
        "inventory_digest": "3e480a9fcf44da65a07aa1fcad8e981911006568d23b89ad8891f26a5d96e69e",
        "candidate_ids": [], "fixture_manifest_path": "fixture-manifest.json", "fixture_manifest_sha256": sha((ROOT / "fixture-manifest.json").read_bytes()),
        "input_hashes": {p["short_id"]: {"pin": p["expected_rev"], "source_raw_sha256": p["captures"]["source"]["sha256"], "canonical_block_sha256": p["canonical_block_sha256"], "public_raw_sha256": p["captures"]["public"]["sha256"], "email_raw_sha256": p["captures"]["email"]["sha256"], "cli_raw_sha256": p["captures"]["cli"]["sha256"]} for p in capture["papers"]},
        "commands_or_probes": ["python3 scripts/capture.py", "python3 scripts/build_report.py", "python3 scripts/verify.py (twice)"],
        "observed_facts": observations,
        "inferences": ["The current format is not reader-safe because hard semantic, geometry, accessibility, and revision-identity thresholds fail.", "PDS44 is a useful narrow-geometry and low-spacer control by dimension, but is not an unconditional gold fixture."],
        "recommendations": ["Carry this frozen baseline unchanged into Round 2 candidate scoring.", "Require authenticated Studio, real AT, and delivered real-mail-client evidence before any format can win.", "Use PDS44 as dimension-specific control and CCH29/PDS45/CCH28 as known-bad targets; do not label any whole Paper gold."],
        "unresolved_unknowns": gaps["carried_risks"], "surface_matrix": surface, "threshold_results": gates,
        "evidence_paths": ["outputs/capture-manifest.json", "outputs/baseline-observations.json", "outputs/text-parity.json", "outputs/threshold-scorecard.json", "outputs/failure-taxonomy.json", "outputs/surface-matrix.json", "outputs/gaps.json", "outputs/transient-500-observations.json", "fixture-manifest.json"],
        "validation": {"verifier": "scripts/verify.py", "required_runs": 2}, "risks": gaps,
        "stop_condition": "Reproducible Round-1 baseline frozen; no repair candidate built; hard failures and capability blocks remain explicit.",
        "verdict": "BASELINE_FAIL_WITH_BLOCKED_SURFACES"
    }
    write(ROOT / "result.json", result)


if __name__ == "__main__": main()
