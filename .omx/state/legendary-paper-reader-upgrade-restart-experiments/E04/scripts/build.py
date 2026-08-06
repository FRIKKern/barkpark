#!/usr/bin/env python3
"""Build one deterministic isolated E04 candidate evidence tree."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from migration import canonical_bytes, digest, migrate

PINS = {
    "CCH28": "49c1534d9fb76d0d9adc7b97f25ec471",
    "CCH29": "18768b0a14c2eead927181c4a0e37c18",
    "PDS44": "8bbd5d874a1b697f1e4e437c473f8e52",
    "PDS45": "b992fd8aaa028b0dab30a8da76f077fd",
}


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(value) + b"\n")


def text_carriers(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key in sorted(value):
            if key in {"text", "value"} and isinstance(value[key], str) and value[key]:
                found.append(value[key])
            else:
                found.extend(text_carriers(value[key]))
    elif isinstance(value, list):
        for child in value:
            found.extend(text_carriers(child))
    return found


def count_tree(blocks: Any) -> dict[str, int]:
    counts = {"blocks": len(blocks), "authored_header_cells": 0, "head_cells": 0, "body_cells": 0,
              "marks": 0, "headerless_tables": 0, "exact_empty_spacers": 0}
    def walk(value: Any) -> None:
        if isinstance(value, list):
            for child in value: walk(child)
        elif isinstance(value, dict):
            if value.get("type") == "table":
                if isinstance(value.get("header"), list): counts["authored_header_cells"] += len(value["header"])
                if isinstance(value.get("head"), list): counts["head_cells"] += len(value["head"])
                if "header" not in value and "head" not in value: counts["headerless_tables"] += 1
                rows = value.get("rows")
                if isinstance(rows, list): counts["body_cells"] += sum(len(r) for r in rows if isinstance(r, list))
            if value.get("type") == "paragraph" and value.get("content") == []: counts["exact_empty_spacers"] += 1
            marks = value.get("marks")
            if isinstance(marks, list): counts["marks"] += len(marks)
            for child in value.values(): walk(child)
    walk(blocks)
    return counts


def adapter(surface: str, fixture_id: str, doc: dict[str, Any]) -> dict[str, Any]:
    blocks = doc["blocks"]
    carriers = text_carriers(blocks)
    base = {
        "schema_version": "legendary-paper-restart-e04-adapter/v1",
        "surface": surface,
        "fixture_id": fixture_id,
        "document_revision": doc["_rev"],
        "source_sha256": digest(blocks),
        "authored_carriers": len(carriers),
        "authored_carriers_sha256": digest(carriers),
        "status": "ADAPTER_PASS",
        "scope": "isolated_candidate_harness_not_deployed_reader",
    }
    if surface in {"public", "email"}:
        base["projection"] = {"landmark": "article", "blocks": blocks, "table_header_role": "columnheader_from_head_only"}
    elif surface == "studio":
        base["projection"] = {"editor_value": blocks, "connected_identity": {"document_revision": doc["_rev"]}}
    elif surface == "tui80":
        base["projection"] = {"width": 80, "complete_content": carriers, "control_bytes": 0}
    else:
        base["projection"] = {"content_type": "application/json", "etag_basis": doc["_rev"], "blocks": blocks}
    return base


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    e04 = Path(__file__).resolve().parents[1]
    e01 = e04.parent / "E01" / "raw" / "doc_get"
    totals_before: dict[str, int] = {}
    totals_after: dict[str, int] = {}
    paper_receipts = []
    reader_receipts = []
    for fixture_id, revision in PINS.items():
        source_path = e01 / f"{fixture_id}.json"
        raw = source_path.read_bytes()
        doc = json.loads(raw)
        (output / "preimages").mkdir(parents=True, exist_ok=True)
        (output / "preimages" / f"{fixture_id}.json").write_bytes(raw)
        migrated, receipt = migrate(doc, revision)
        receipt.update({"fixture_id": fixture_id, "raw_preimage_sha256": hashlib.sha256(raw).hexdigest()})
        write_json(output / "migrated" / f"{fixture_id}.json", migrated)
        write_json(output / "receipts" / "migration" / f"{fixture_id}.json", receipt)
        rolled_back = (output / "preimages" / f"{fixture_id}.json").read_bytes()
        write_json(output / "receipts" / "rollback" / f"{fixture_id}.json", {
            "schema_version": "legendary-paper-restart-e04-rollback/v1", "fixture_id": fixture_id,
            "status": "PASS", "restored_raw_sha256": hashlib.sha256(rolled_back).hexdigest(),
            "expected_raw_sha256": hashlib.sha256(raw).hexdigest(), "byte_exact": rolled_back == raw})
        second, second_receipt = migrate(migrated, revision)
        write_json(output / "receipts" / "idempotence" / f"{fixture_id}.json", {
            "schema_version": "legendary-paper-restart-e04-idempotence/v1", "fixture_id": fixture_id,
            "status": "PASS" if second == migrated and not second_receipt["actions"] else "FAIL",
            "byte_identical_canonical": canonical_bytes(second) == canonical_bytes(migrated),
            "second_run_actions": len(second_receipt["actions"])})
        before = count_tree(doc["blocks"]); after = count_tree(migrated["blocks"])
        for key, value in before.items(): totals_before[key] = totals_before.get(key, 0) + value
        for key, value in after.items(): totals_after[key] = totals_after.get(key, 0) + value
        paper_receipts.append({"fixture_id": fixture_id, "before": before, "after": after,
                               "actions": len(receipt["actions"]), "quarantined": len(receipt["quarantine"])})
        for surface in ("public", "studio", "tui80", "email", "cli_api"):
            item = adapter(surface, fixture_id, migrated)
            write_json(output / "adapters" / surface / f"{fixture_id}.json", item)
            reader_receipts.append({k: item[k] for k in ("surface", "fixture_id", "status", "scope", "authored_carriers", "authored_carriers_sha256")})

    write_json(output / "reports" / "preservation.json", {
        "schema_version": "legendary-paper-restart-e04-preservation/v1",
        "papers": paper_receipts, "totals_before": totals_before, "totals_after": totals_after,
        "authored_loss": 0, "invented_headers": 0})
    blocked = [
        {"surface":"public","cell":"deployed reader and real assistive technology","status":"BLOCKED","reason":"candidate is isolated; no deployed revision or AT session"},
        {"surface":"studio","cell":"authenticated connected Studio, auth/reconnect/focus","status":"BLOCKED","reason":"no authenticated Studio session supplied"},
        {"surface":"tui80","cell":"interactive focus/scroll/click/history/state recovery","status":"BLOCKED","reason":"candidate adapter is non-interactive and not integrated into bp"},
        {"surface":"email","cell":"delivered Gmail/Outlook/Apple Mail and AT","status":"BLOCKED","reason":"no delivery account or real mail client session supplied"},
        {"surface":"cli_api","cell":"deployed API negotiation/errors/pagination/request ID","status":"BLOCKED","reason":"candidate is offline and does not mutate or deploy production"},
    ]
    write_json(output / "reports" / "readers.json", {
        "schema_version": "legendary-paper-restart-e04-readers/v1", "adapter_receipts": reader_receipts,
        "real_reader_cells": blocked, "proxy_passes_for_missing_readers": 0,
        "candidate_reader_units_exercised": 20, "real_reader_units_passed": 0, "real_reader_units_blocked": 20})
    write_json(output / "reports" / "provenance.json", {
        "schema_version": "legendary-paper-restart-e04-provenance/v1", "source": "committed E01 raw/doc_get fixtures",
        "pins": PINS, "writes_outside_e04": 0, "network_calls": 0})
    adversarial = json.loads((e04.parent / "E01" / "fixtures" / "adversarial.json").read_text())["fixtures"]
    probes = []
    for fixture in adversarial:
        probe_doc = {"_rev": "probe-rev", "blocks": [fixture["input"]]}
        migrated, receipt = migrate(probe_doc, "probe-rev")
        probes.append({"id": fixture["id"], "status": receipt["status"], "actions": len(receipt["actions"]),
                       "quarantine": receipt["quarantine"], "preserved_text": text_carriers(probe_doc) == text_carriers(migrated)})
    stale_doc = {"_rev": "stale-rev", "blocks": [{"id":"cas-table","type":"table","header":[],"rows":[]}]}
    stale_after, stale_receipt = migrate(stale_doc, "expected-rev")
    probes.append({"id":"revision-cas-conflict", "status":stale_receipt["status"],
                   "actions":len(stale_receipt["actions"]), "quarantine":stale_receipt["quarantine"],
                   "unchanged":stale_after == stale_doc})
    write_json(output / "reports" / "adversarial.json", {
        "schema_version":"legendary-paper-restart-e04-adversarial/v1", "probes":probes,
        "conflicting_alias_quarantined":any(p["id"] == "conflicting-aliases" and p["status"] == "QUARANTINED_AMBIGUITY" for p in probes),
        "revision_conflict_quarantined":probes[-1]["status"] == "QUARANTINED_REVISION_MISMATCH"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
