#!/usr/bin/env python3
"""Build the E01 canonical losslessness/structure baseline without mutations."""

from __future__ import annotations

import hashlib
import html
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "raw"
FIXTURES = ROOT / "fixtures"
REPORTS = ROOT / "reports"
BASE_URL = "https://guerrilla.barkpark.cloud"
INVENTORY_DIGEST = "3e480a9fcf44da65a07aa1fcad8e981911006568d23b89ad8891f26a5d96e69e"
PAPERS = [
    {
        "fixture_id": "CCH29",
        "slug": "cloud-console-hardening-wave-29-2026-08-03",
        "revision": "18768b0a14c2eead927181c4a0e37c18",
    },
    {
        "fixture_id": "PDS45",
        "slug": "pds-wave-45-2026-08-03",
        "revision": "b992fd8aaa028b0dab30a8da76f077fd",
    },
    {
        "fixture_id": "CCH28",
        "slug": "cloud-console-hardening-wave-28-2026-08-03",
        "revision": "49c1534d9fb76d0d9adc7b97f25ec471",
    },
    {
        "fixture_id": "PDS44",
        "slug": "pds-wave-44-2026-08-03",
        "revision": "8bbd5d874a1b697f1e4e437c473f8e52",
    },
]


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def write_json(path: Path, value: Any) -> None:
    write_bytes(path, json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode() + b"\n")


def run(*args: str) -> tuple[bytes, float]:
    started = time.perf_counter()
    last_error = ""
    for attempt in range(1, 5):
        proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode == 0:
            return proc.stdout, time.perf_counter() - started
        last_error = proc.stderr.decode("utf-8", "replace").strip()
        if attempt < 4:
            time.sleep(attempt * 0.5)
    raise RuntimeError(f"command failed after 4 attempts ({' '.join(args)}): {last_error}")


def fetch(path: str) -> tuple[bytes, dict[str, str], float]:
    started = time.perf_counter()
    last_error: Exception | None = None
    for attempt in range(1, 5):
        request = urllib.request.Request(BASE_URL + path, headers={"User-Agent": "barkpark-e01-baseline/1"})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                body = response.read()
                headers = {key.lower(): value for key, value in response.headers.items()}
                status = response.status
            if status != 200:
                raise RuntimeError(f"GET {path} returned {status}")
            return body, headers, time.perf_counter() - started
        except (urllib.error.URLError, TimeoutError, RuntimeError) as exc:
            last_error = exc
            if attempt < 4:
                time.sleep(attempt * 0.5)
    raise RuntimeError(f"GET {path} failed after 4 attempts: {last_error}")


def walk(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def inline_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "".join(inline_text(child) for child in value)
    if isinstance(value, dict):
        return str(value.get("value", value.get("text", ""))) + inline_text(value.get("content", []))
    return ""


def paragraph_text(block: dict[str, Any]) -> str:
    return inline_text(block.get("content", block.get("text", "")))


def is_exact_empty_spacer(block: dict[str, Any]) -> bool:
    return block.get("type") == "paragraph" and paragraph_text(block).strip() == ""


def row_cells(row: Any) -> list[Any]:
    if isinstance(row, list):
        return row
    if isinstance(row, dict) and isinstance(row.get("cells"), list):
        return row["cells"]
    return []


def nested_paragraph_items(doc: dict[str, Any]) -> list[dict[str, Any]]:
    found = []
    for block in doc["blocks"]:
        if block.get("type") != "list":
            continue
        for index, item in enumerate(block.get("items", [])):
            if isinstance(item, list) and len(item) == 1 and isinstance(item[0], dict) and item[0].get("type") == "paragraph":
                text = inline_text(item[0].get("content", []))
                found.append({"block_id": block.get("id"), "item_index": index, "text": text})
    return found


def census(doc: dict[str, Any]) -> dict[str, Any]:
    blocks = doc["blocks"]
    tables = [block for block in blocks if block.get("type") == "table"]
    marks = [mark for node in walk(blocks) for mark in node.get("marks", []) if isinstance(node.get("marks"), list)]
    nested = nested_paragraph_items(doc)
    return {
        "revision": doc.get("_rev"),
        "block_count": len(blocks),
        "unique_block_ids": len({block.get("id") for block in blocks}),
        "heading_count": sum(block.get("type") == "heading" for block in blocks),
        "table_count": len(tables),
        "legacy_header_cells": sum(len(block.get("header") or []) for block in tables),
        "modern_head_cells": sum(len(block.get("head") or []) for block in tables),
        "headerless_tables": sum(not (block.get("header") or block.get("head")) for block in tables),
        "body_cells": sum(len(row_cells(row)) for block in tables for row in block.get("rows", [])),
        "callout_count": sum(block.get("type") == "callout" for block in blocks),
        "mark_records": len(marks),
        "exact_empty_spacers": sum(is_exact_empty_spacer(block) for block in blocks),
        "nested_paragraph_list_items": len(nested),
        "nested_paragraph_list_words": sum(len(re.findall(r"\b\w+\b", item["text"], re.UNICODE)) for item in nested),
        "nested_paragraph_list_characters": sum(len(item["text"]) for item in nested),
        "canonical_document_sha256": sha256(canonical_bytes(doc)),
        "canonical_blocks_sha256": sha256(canonical_bytes(blocks)),
        "ordered_block_ids_sha256": sha256(canonical_bytes([block.get("id") for block in blocks])),
    }


def html_text(body: bytes) -> str:
    text = re.sub(r"<script\b[^>]*>.*?</script>", " ", body.decode("utf-8", "replace"), flags=re.I | re.S)
    text = re.sub(r"<style\b[^>]*>.*?</style>", " ", text, flags=re.I | re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    return " ".join(html.unescape(text).split())


def nested_survival(text: str, nested: list[dict[str, Any]]) -> dict[str, Any]:
    normalized = " ".join(text.split())
    survived = [item for item in nested if " ".join(item["text"].split()) in normalized]
    return {
        "items_total": len(nested),
        "items_survived": len(survived),
        "items_lost": len(nested) - len(survived),
        "words_total": sum(len(re.findall(r"\b\w+\b", item["text"], re.UNICODE)) for item in nested),
        "words_survived": sum(len(re.findall(r"\b\w+\b", item["text"], re.UNICODE)) for item in survived),
    }


def first_node_with_mark(doc: dict[str, Any], mark_kind: type) -> dict[str, Any]:
    for node in walk(doc["blocks"]):
        marks = node.get("marks")
        if isinstance(marks, list) and marks and isinstance(marks[0], mark_kind):
            return node
    raise RuntimeError(f"no mark fixture of {mark_kind}")


def build_fixture_sets(docs: dict[str, dict[str, Any]]) -> None:
    cch29 = docs["CCH29"]
    pds45 = docs["PDS45"]
    header_table = next(block for block in cch29["blocks"] if block.get("type") == "table" and block.get("header"))
    headerless_table = next(block for block in pds45["blocks"] if block.get("type") == "table" and not block.get("header") and not block.get("head"))
    flat_list = next(block for block in pds45["blocks"] if block.get("type") == "list")
    nested_block = next(block for block in cch29["blocks"] if block.get("type") == "list" and nested_paragraph_items({"blocks": [block]}))
    explicit_tone = next(block for block in cch29["blocks"] if block.get("type") == "callout" and block.get("tone"))
    missing_tone = next(block for block in pds45["blocks"] if block.get("type") == "callout" and "tone" not in block)
    empty = next(block for block in cch29["blocks"] if is_exact_empty_spacer(block))
    nonempty = next(block for block in cch29["blocks"] if block.get("type") == "paragraph" and not is_exact_empty_spacer(block))

    controls = {
        "schema_version": "legendary-paper-e01-controls/v1",
        "dimensions": {
            "legacy_header": {"source": "CCH29", "block": header_table, "expected_cells": len(header_table["header"])},
            "genuinely_headerless": {"source": "PDS45", "block": headerless_table, "expected_cells": 0},
            "flat_list": {"source": "PDS45", "block": flat_list, "expected_item_count": len(flat_list.get("items", []))},
            "nested_list": {"source": "CCH29", "block": nested_block, "expected_wrapped_items": len(nested_paragraph_items({"blocks": [nested_block]}))},
            "string_mark": {"source": "CCH29", "node": first_node_with_mark(cch29, str)},
            "object_mark": {"source": "PDS45", "node": first_node_with_mark(pds45, dict)},
            "explicit_tone": {"source": "CCH29", "block": explicit_tone},
            "missing_tone": {"source": "PDS45", "block": missing_tone},
            "exact_empty_spacer": {"source": "CCH29", "block": empty, "expected_empty": True},
            "nonempty_paragraph": {"source": "CCH29", "block": nonempty, "expected_empty": False},
        },
    }
    bad = {
        "schema_version": "legendary-paper-e01-known-bad/v1",
        "targets": [
            {"id": "legacy-header-reader-drop", "source": "all", "observed_count": 113, "failure": "Studio and terminal adapters read head but not legacy header."},
            {"id": "nested-list-reader-drop", "source": "CCH29", "observed_items": 11, "observed_words": 406, "failure": "Paragraph-wrapped list items are blank in email and terminal projections."},
            {"id": "mixed-mark-vocabulary", "source": "all", "observed_count": 388, "failure": "String and object mark vocabularies do not retain semantic distinction on every reader."},
            {"id": "empty-spacer-overload", "source": "all", "observed_count": 381, "failure": "Exact-empty authored paragraphs inflate source/editing structure."},
            {"id": "genuinely-headerless", "source": "PDS45/PDS44", "observed_tables": 11, "failure": "No header intent is encoded; automatic promotion would be an unsupported guess."},
        ],
    }
    adversarial = {
        "schema_version": "legendary-paper-e01-adversarial/v1",
        "frozen_before_candidate_rounds": True,
        "fixtures": [
            {"id": "header-only", "dimension": "header_head", "input": {"type": "table", "header": ["legacy"], "rows": [["body"]]}, "expected": "preserve legacy header"},
            {"id": "head-only", "dimension": "header_head", "input": {"type": "table", "head": ["modern"], "rows": [["body"]]}, "expected": "preserve modern head"},
            {"id": "header-head-equal", "dimension": "header_head", "input": {"type": "table", "header": ["same"], "head": ["same"], "rows": [["body"]]}, "expected": "accept equal aliases"},
            {"id": "header-head-conflict", "dimension": "header_head", "input": {"type": "table", "header": ["legacy"], "head": ["modern"], "rows": [["body"]]}, "expected": "quarantine conflict; do not pick silently"},
            {"id": "list-flat-inline", "dimension": "list", "input": {"type": "list", "items": [[{"type": "text", "value": "flat words"}]]}, "expected_words": 2},
            {"id": "list-paragraph-wrapped", "dimension": "list", "input": {"type": "list", "items": [[{"type": "paragraph", "content": [{"type": "text", "value": "nested words survive"}]}]]}, "expected_words": 3},
            {"id": "list-mixed-malformed", "dimension": "list", "input": {"type": "list", "items": [None, "scalar", [{"type": "unknown", "value": "opaque"}]]}, "expected": "explicit degradation, never silent blank for authored text"},
            {"id": "mark-string", "dimension": "mark", "input": {"type": "text", "value": "strong", "marks": ["strong"]}, "expected": "strong"},
            {"id": "mark-object", "dimension": "mark", "input": {"type": "text", "value": "code", "marks": [{"type": "code"}]}, "expected": "code"},
            {"id": "mark-mixed-duplicate", "dimension": "mark", "input": {"type": "text", "value": "mixed", "marks": ["strong", {"type": "strong"}, {"type": "unknown"}]}, "expected": "deduplicate supported semantics and quarantine unsupported mark"},
            {"id": "tone-aliases", "dimension": "tone", "inputs": ["info", "note", "warn", "warning", "error", "danger", None, "unknown"], "expected": "one documented mapping with explicit unknown degradation"},
            {"id": "empty-exact", "dimension": "empty_spacer", "input": {"type": "paragraph", "content": []}, "expected_empty": True},
            {"id": "empty-whitespace", "dimension": "empty_spacer", "input": {"type": "paragraph", "content": [{"type": "text", "value": "  \n\t"}]}, "expected_empty": True},
            {"id": "empty-nbsp", "dimension": "empty_spacer", "input": {"type": "paragraph", "content": [{"type": "text", "value": "\u00a0"}]}, "expected_empty": True},
            {"id": "empty-zero-width", "dimension": "empty_spacer", "input": {"type": "paragraph", "content": [{"type": "text", "value": "\u200b"}]}, "expected": "not exact-empty; explicit policy required"},
        ],
    }
    for name, value in (("controls.json", controls), ("known-bad.json", bad), ("adversarial.json", adversarial)):
        write_json(FIXTURES / name, value)


def artifact_manifest() -> dict[str, Any]:
    excluded = {"reports/hash-manifest.json", "reports/timing.json", "reports/verification.json"}
    files = []
    for path in sorted(p for p in ROOT.rglob("*") if p.is_file()):
        rel = path.relative_to(ROOT).as_posix()
        if rel in excluded or rel.startswith("__pycache__/") or "/__pycache__/" in rel:
            continue
        data = path.read_bytes()
        files.append({"path": rel, "bytes": len(data), "sha256": sha256(data)})
    return {
        "schema_version": "legendary-paper-e01-hash-manifest/v1",
        "excluded_from_stable_set": sorted(excluded),
        "files": files,
        "artifact_set_sha256": sha256(canonical_bytes(files)),
    }


def main() -> None:
    started = time.perf_counter()
    for directory in (RAW, FIXTURES / "source", REPORTS):
        directory.mkdir(parents=True, exist_ok=True)

    docs: dict[str, dict[str, Any]] = {}
    paper_reports = []
    reader_reports = []
    timing_rows = []

    for paper in PAPERS:
        fixture_id = paper["fixture_id"]
        slug = paper["slug"]
        raw_doc, elapsed = run("bp", "doc", "get", "paper", slug, "--perspective", "published", "-o", "json")
        timing_rows.append({"fixture_id": fixture_id, "probe": "cli_api", "seconds": round(elapsed, 6)})
        doc = json.loads(raw_doc)
        if doc.get("_rev") != paper["revision"]:
            raise RuntimeError(f"{fixture_id} revision drift: {doc.get('_rev')} != {paper['revision']}")
        docs[fixture_id] = doc
        write_bytes(RAW / "api" / f"{fixture_id}.json", raw_doc)
        write_bytes(FIXTURES / "source" / f"{fixture_id}.json", canonical_bytes(doc) + b"\n")

        source_body, source_headers, elapsed = fetch(f"/papers/{slug}/source")
        timing_rows.append({"fixture_id": fixture_id, "probe": "source", "seconds": round(elapsed, 6)})
        source = json.loads(source_body)
        write_bytes(RAW / "source" / f"{fixture_id}.json", source_body)
        if source.get("_rev") != paper["revision"] or source.get("source", {}).get("blocks") != doc["blocks"]:
            raise RuntimeError(f"{fixture_id} /source diverges from CLI/API source")

        public_body, public_headers, elapsed = fetch(f"/papers/{slug}")
        timing_rows.append({"fixture_id": fixture_id, "probe": "public", "seconds": round(elapsed, 6)})
        write_bytes(RAW / "public" / f"{fixture_id}.html", public_body)
        email_body, email_headers, elapsed = fetch(f"/papers/{slug}/email")
        timing_rows.append({"fixture_id": fixture_id, "probe": "email", "seconds": round(elapsed, 6)})
        write_bytes(RAW / "email" / f"{fixture_id}.html", email_body)

        tui_body, elapsed = run("bp", "paper", "view", slug, "--width", "80", "--profile", "none", "--perspective", "published")
        timing_rows.append({"fixture_id": fixture_id, "probe": "tui80", "seconds": round(elapsed, 6)})
        write_bytes(RAW / "tui80" / f"{fixture_id}.txt", tui_body)

        row = {"fixture_id": fixture_id, "slug": slug, **census(doc)}
        paper_reports.append(row)
        nested = nested_paragraph_items(doc)
        public_text = html_text(public_body)
        email_text = html_text(email_body)
        tui_text = tui_body.decode("utf-8", "replace")
        reader_reports.append(
            {
                "fixture_id": fixture_id,
                "revision": paper["revision"],
                "cli_api": {"status": "pass", "bytes": len(raw_doc), "sha256": sha256(raw_doc), "canonical_blocks_sha256": row["canonical_blocks_sha256"]},
                "source": {"status": "pass", "bytes": len(source_body), "sha256": sha256(source_body), "content_type": source_headers.get("content-type")},
                "public": {
                    "status": "captured",
                    "bytes": len(public_body),
                    "sha256": sha256(public_body),
                    "content_type": public_headers.get("content-type"),
                    "data_block_id_instances": len(re.findall(rb"\bdata-block-id=", public_body)),
                    "legacy_header_th_instances": len(re.findall(rb"<th\b", public_body, re.I)),
                    "presentation_table_instances": len(re.findall(rb"<table\b[^>]*\brole=[\"']presentation[\"']", public_body, re.I)),
                    "nested_list_survival": nested_survival(public_text, nested),
                },
                "email": {
                    "status": "captured",
                    "bytes": len(email_body),
                    "sha256": sha256(email_body),
                    "content_type": email_headers.get("content-type"),
                    "legacy_header_th_instances": len(re.findall(rb"<th\b", email_body, re.I)),
                    "presentation_table_instances": len(re.findall(rb"<table\b[^>]*\brole=[\"']presentation[\"']", email_body, re.I)),
                    "nested_list_survival": nested_survival(email_text, nested),
                },
                "tui80": {
                    "status": "captured",
                    "bytes": len(tui_body),
                    "sha256": sha256(tui_body),
                    "line_count": len(tui_text.splitlines()),
                    "max_codepoint_width": max((len(line) for line in tui_text.splitlines()), default=0),
                    "nested_list_survival": nested_survival(tui_text, nested),
                },
                "studio": {
                    "status": "source-proven/current-adapter-static",
                    "note": "The authenticated reader was not mutated or GUI-driven in E01. Current tableBlockToNode reads block.head only; all 113 live cells are under block.header.",
                    "adapter_source": "api/assets/paper-editor/src/canvas/run-convert.js:1674",
                },
            }
        )

    totals_keys = [
        "block_count", "heading_count", "table_count", "legacy_header_cells", "modern_head_cells",
        "headerless_tables", "body_cells", "callout_count", "mark_records", "exact_empty_spacers",
        "nested_paragraph_list_items", "nested_paragraph_list_words", "nested_paragraph_list_characters",
    ]
    totals = {key: sum(row[key] for row in paper_reports) for key in totals_keys}
    census_report = {
        "schema_version": "legendary-paper-e01-census/v1",
        "inventory_digest": INVENTORY_DIGEST,
        "papers": paper_reports,
        "totals": totals,
        "observations": [
            "All four revision pins reproduced from the current published CLI/API source.",
            "All 815 top-level canonical blocks have unique ids within their Paper and stable order hashes.",
            "All 113 authored table-header cells use legacy header; no live table uses modern head.",
            "Exactly 1,374 body cells, 388 mark records, and 381 exact-empty spacers are present.",
            "CCH29 alone contains 11 paragraph-wrapped list items totaling 406 words and 2,268 characters.",
        ],
        "preferences": [],
    }
    write_json(REPORTS / "census.json", census_report)
    write_json(REPORTS / "reader-probes.json", {"schema_version": "legendary-paper-e01-reader-probes/v1", "papers": reader_reports})
    build_fixture_sets(docs)

    thresholds = {
        "schema_version": "legendary-paper-e01-thresholds/v1",
        "declared_before_round_2": True,
        "hard_thresholds": {
            "revision_match": {"expected": "4/4"},
            "canonical_block_accounting": {"expected": 815, "allowed_loss": 0},
            "legacy_header_cell_accounting": {"expected": 113, "allowed_loss": 0},
            "genuinely_headerless_table_accounting": {"expected": 11, "allowed_implicit_promotion": 0},
            "body_cell_accounting": {"expected": 1374, "allowed_loss_or_reorder": 0},
            "mark_record_accounting": {"expected": 388, "allowed_silent_loss": 0},
            "exact_empty_spacer_accounting": {"expected": 381, "allowed_unfenced_change": 0},
            "cch29_nested_list_words": {"expected": 406, "allowed_loss": 0},
            "alias_conflict_behavior": {"expected": "quarantine", "allowed_silent_precedence": 0},
            "idempotent_verification": {"expected": "two runs return the same artifact_set_sha256"},
        },
        "baseline_not_candidate_acceptance": "Current readers are expected to fail some thresholds; E01 establishes denominators and tripwires, not a winner.",
    }
    write_json(REPORTS / "thresholds.json", thresholds)

    taxonomy = {
        "schema_version": "legendary-paper-e01-failure-taxonomy/v1",
        "observed": [
            {"code": "L01_HEADER_ALIAS_DROP", "severity": "hard", "scope": "Studio/TUI/human CLI", "denominator": 113, "fact": "Live headers are stored as header while these adapters consume head."},
            {"code": "L02_NESTED_LIST_DROP", "severity": "hard", "scope": "CCH29 public/email/TUI projections", "denominator": 406, "fact": "Eleven paragraph-wrapped list items do not survive the current projections."},
            {"code": "L03_MARK_SEMANTIC_DIVERGENCE", "severity": "hard", "scope": "cross-reader", "denominator": 388, "fact": "Both string and object mark vocabularies occur; no current human reader preserves all semantic distinctions."},
            {"code": "L04_TONE_DEGRADATION", "severity": "hard", "scope": "callouts", "denominator": 30, "fact": "Alias, missing, and unknown tones do not share one explicit cross-reader semantic mapping."},
            {"code": "L05_EMPTY_SPACER_DEBT", "severity": "quality", "scope": "canonical source", "denominator": 381, "fact": "Exact-empty paragraphs are authored source blocks and require revision-fenced handling."},
            {"code": "L06_HEADERLESS_INTENT_UNKNOWN", "severity": "quarantine", "scope": "11 tables", "denominator": 11, "fact": "No header field is authored; promoting a body row would infer intent."},
            {"code": "L07_ALIAS_CONFLICT", "severity": "quarantine", "scope": "adversarial", "denominator": 1, "fact": "Conflicting header/head values have no safe silent precedence."},
        ],
        "inferences": [
            "A candidate needs an explicit dual-vocabulary resolver before any source migration can be considered lossless.",
            "Reader-specific success cannot be inferred from canonical JSON preservation alone.",
        ],
        "preferences": [
            "No candidate format or precedence policy is selected by E01.",
        ],
    }
    write_json(REPORTS / "failure-taxonomy.json", taxonomy)

    assignment = {
        "schema_version": "legendary-paper-e01-assignment/v1",
        "assignment_id": "experiment-01",
        "round": 1,
        "round_name": "Baseline",
        "epic_id": "task-a768c69e659add58",
        "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-05",
        "wave_revision": "a06716c4-2dd5-4bda-b9a9-a484b009abb2",
        "inventory_digest": INVENTORY_DIGEST,
        "assignment_snapshot_digest": "2470a55801252509f473edd85f1a9a1d47d332ca6e86213f45b81fbc01d2eb89",
        "candidate_ids": [],
        "papers": PAPERS,
        "write_boundary": ROOT.relative_to(Path.cwd()).as_posix() if ROOT.is_relative_to(Path.cwd()) else str(ROOT),
        "stop_condition": "Stop when canonical denominators, fixtures, reader captures, taxonomy, thresholds, and stable double-verification are reproducible; do not build a repair candidate.",
    }
    write_json(ROOT / "assignment.json", assignment)

    manifest = artifact_manifest()
    write_json(REPORTS / "hash-manifest.json", manifest)
    write_json(
        REPORTS / "timing.json",
        {
            "schema_version": "legendary-paper-e01-timing/v1",
            "probe_seconds": timing_rows,
            "probe_seconds_total": round(sum(row["seconds"] for row in timing_rows), 6),
            "build_wall_seconds": round(time.perf_counter() - started, 6),
            "note": "Timing is observational and excluded from the stable artifact-set hash.",
        },
    )
    print(json.dumps({"status": "built", "artifact_set_sha256": manifest["artifact_set_sha256"], "totals": totals}, sort_keys=True))


if __name__ == "__main__":
    main()
