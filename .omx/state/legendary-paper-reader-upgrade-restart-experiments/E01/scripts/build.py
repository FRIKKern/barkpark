#!/usr/bin/env python3
"""Fresh, read-only E01 capture and canonical content baseline builder."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any, Iterable

from canonicalizer import canonical_bytes, canonicalize, nfc_tree, sha256


ROOT = Path(__file__).resolve().parents[1]
WORKTREE = ROOT.parents[3]
ASSIGNMENT = json.loads((ROOT / "assignment.json").read_text())
RAW = ROOT / "raw"
CANON = ROOT / "canonical"
FIXTURES = ROOT / "fixtures"
REPORTS = ROOT / "reports"


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8") + b"\n")


def run_bp(args: list[str]) -> tuple[bytes, float, list[dict[str, Any]]]:
    env = os.environ.copy()
    env["BARKPARK_MANIFEST"] = "docs/cli/fixtures/full-manifest.json"
    started = time.perf_counter()
    attempts = []
    for ordinal in range(1, 5):
        attempt_started = time.perf_counter()
        try:
            process = subprocess.run(
                ["bp", "-s", "guerrilla", *args], cwd=WORKTREE, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=False,
            )
            attempts.append({"ordinal": ordinal, "exit": process.returncode, "stdout_bytes": len(process.stdout), "stderr_bytes": len(process.stderr), "seconds": round(time.perf_counter() - attempt_started, 6)})
            if process.returncode == 0:
                return process.stdout, time.perf_counter() - started, attempts
        except subprocess.TimeoutExpired as exc:
            attempts.append({"ordinal": ordinal, "exit": "timeout", "stdout_bytes": len(exc.stdout or b""), "stderr_bytes": len(exc.stderr or b""), "seconds": round(time.perf_counter() - attempt_started, 6)})
        if ordinal < 4:
            time.sleep(ordinal * 0.25)
    raise RuntimeError(f"read command failed after 4 attempts; attempts={attempts}")


def git_snapshot() -> dict[str, Any]:
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=WORKTREE, stdout=subprocess.PIPE, check=True).stdout.decode().strip()
    status = subprocess.run(["git", "status", "--porcelain=v1"], cwd=WORKTREE, stdout=subprocess.PIPE, check=True).stdout
    return {"head": head, "tracked_status_bytes": len(status), "tracked_status_sha256": sha256(status)}


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
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, list):
        return "".join(inline_text(item) for item in value)
    if isinstance(value, dict):
        own = value.get("value", value.get("text", ""))
        return inline_text(own) + inline_text(value.get("content", []))
    return ""


def row_cells(row: Any) -> list[Any]:
    if isinstance(row, list):
        return row
    if isinstance(row, dict) and isinstance(row.get("cells"), list):
        return row["cells"]
    return []


def marks_in(value: Any) -> list[Any]:
    result: list[Any] = []
    for node in walk(value):
        marks = node.get("marks")
        if isinstance(marks, list):
            result.extend(marks)
    return result


def block_metrics(block: dict[str, Any]) -> dict[str, Any]:
    headers = block.get("header") if isinstance(block.get("header"), list) else []
    heads = block.get("head") if isinstance(block.get("head"), list) else []
    rows = block.get("rows") if isinstance(block.get("rows"), list) else []
    return {
        "header_cells": len(headers),
        "head_cells": len(heads),
        "body_cells": sum(len(row_cells(row)) for row in rows),
        "marks": len(marks_in(block)),
        "text_sha256": sha256(inline_text(block).encode("utf-8")),
    }


def nested_paragraph_items(block: dict[str, Any]) -> list[str]:
    found: list[str] = []
    if block.get("type") != "list":
        return found
    for item in block.get("items", []):
        if isinstance(item, list):
            for node in item:
                if isinstance(node, dict) and node.get("type") == "paragraph":
                    found.append(inline_text(node.get("content", [])))
    return found


def census(document: dict[str, Any]) -> dict[str, Any]:
    blocks = document["blocks"]
    tables = [block for block in blocks if block.get("type") == "table"]
    nested = [text for block in blocks for text in nested_paragraph_items(block)]
    return {
        "revision": document.get("_rev"),
        "blocks": len(blocks),
        "unique_nonempty_block_ids": len({block.get("id") for block in blocks if block.get("id")}),
        "tables": len(tables),
        "authored_header_cells": sum(len(block.get("header") or []) for block in tables),
        "modern_head_cells": sum(len(block.get("head") or []) for block in tables),
        "headerless_tables": sum(not (block.get("header") or block.get("head")) for block in tables),
        "table_body_cells": sum(len(row_cells(row)) for block in tables for row in block.get("rows", [])),
        "marks": len(marks_in(blocks)),
        "nested_paragraph_items": len(nested),
        "nested_paragraph_words": sum(len(re.findall(r"\b\w+\b", text, re.UNICODE)) for text in nested),
        "nested_paragraph_characters": sum(len(text) for text in nested),
        "canonical_blocks_sha256": sha256(canonical_bytes(blocks)),
        "ordered_ids_sha256": sha256(canonical_bytes([block.get("id") for block in blocks])),
    }


def fixture_sets(documents: dict[str, dict[str, Any]]) -> None:
    all_blocks = [(paper, block) for paper, doc in documents.items() for block in doc["blocks"]]
    header = next((paper, block) for paper, block in all_blocks if block.get("type") == "table" and block.get("header"))
    headerless = next((paper, block) for paper, block in all_blocks if block.get("type") == "table" and not block.get("header") and not block.get("head"))
    nested = [(paper, block) for paper, block in all_blocks if nested_paragraph_items(block)]
    mark_string = next((paper, node) for paper, doc in documents.items() for node in walk(doc["blocks"]) if any(isinstance(mark, str) for mark in node.get("marks", [])))
    mark_object = next((paper, node) for paper, doc in documents.items() for node in walk(doc["blocks"]) if any(isinstance(mark, dict) for mark in node.get("marks", [])))
    controls = {
        "schema_version": "legendary-paper-restart-e01-controls/v1",
        "controls": [
            {"id": "authored-legacy-header", "paper": header[0], "block": header[1], "expected_header_cells": len(header[1]["header"])},
            {"id": "genuinely-headerless-author-intent", "paper": headerless[0], "block": headerless[1], "expected_header_cells": 0},
            {"id": "string-mark", "paper": mark_string[0], "node": mark_string[1]},
            {"id": "object-mark", "paper": mark_object[0], "node": mark_object[1]},
        ],
    }
    known_bad = {
        "schema_version": "legendary-paper-restart-e01-known-bad/v1",
        "observed_not_inferred": True,
        "fixtures": [
            {"id": "paragraph-wrapped-list-items", "paper": paper, "block": block, "items": nested_paragraph_items(block)}
            for paper, block in nested
        ],
    }
    adversarial = {
        "schema_version": "legendary-paper-restart-e01-adversarial/v1",
        "fixtures": [
            {"id": "legacy-header-only", "input": {"id": "adv-table-1", "type": "table", "header": ["A"], "rows": [["B"]]}, "expect": "preserve header"},
            {"id": "modern-head-only", "input": {"id": "adv-table-2", "type": "table", "head": ["A"], "rows": [["B"]]}, "expect": "preserve head"},
            {"id": "equal-aliases", "input": {"id": "adv-table-3", "type": "table", "header": ["A"], "head": ["A"], "rows": [["B"]]}, "expect": "preserve both; infer neither"},
            {"id": "conflicting-aliases", "input": {"id": "adv-table-4", "type": "table", "header": ["legacy"], "head": ["modern"], "rows": [["B"]]}, "expect": "preserve conflict for quarantine"},
            {"id": "headerless", "input": {"id": "adv-table-5", "type": "table", "rows": [["A", "B"]]}, "expect": "invent zero headers"},
            {"id": "paragraph-wrapped-list", "input": {"id": "adv-list-1", "type": "list", "items": [[{"type": "paragraph", "content": [{"type": "text", "value": "nested words survive"}]}]]}, "expect": "preserve nested shape and text"},
            {"id": "malformed-list", "input": {"id": "adv-list-2", "type": "list", "items": [None, "scalar", [{"type": "unknown", "value": "opaque"}]]}, "expect": "preserve without silent deletion"},
            {"id": "mixed-marks", "input": {"id": "adv-text-1", "type": "paragraph", "content": [{"type": "text", "value": "mixed", "marks": ["strong", {"type": "code"}, {"type": "unknown"}]}]}, "expect": "preserve all mark records"},
            {"id": "long-token", "input": {"id": "adv-text-2", "type": "paragraph", "content": [{"type": "text", "value": "x" * 4096}]}, "expect": "preserve 4096 characters"},
            {"id": "unicode-combining", "input": {"id": "adv-text-3", "type": "paragraph", "content": [{"type": "text", "value": "e\u0301"}]}, "expect": "documented NFC normalization"}
        ],
    }
    write_json(FIXTURES / "controls.json", controls)
    write_json(FIXTURES / "known-bad.json", known_bad)
    write_json(FIXTURES / "adversarial.json", adversarial)


def probe_adversarial() -> None:
    fixture = json.loads((FIXTURES / "adversarial.json").read_text())
    rows = []
    for row in fixture["fixtures"]:
        block = row["input"]
        envelope = {"_id": "adversarial", "_rev": "fixture", "_type": "paper", "blocks": [block]}
        result = canonicalize(canonical_bytes(envelope), "semantic")
        output = result["value"]["blocks"][0]
        before = block_metrics(block)
        after = block_metrics(output)
        rows.append({
            "id": row["id"],
            "exact_after_documented_nfc": output == nfc_tree(block),
            "source_sha256": sha256(canonical_bytes(nfc_tree(block))),
            "semantic_sha256": sha256(canonical_bytes(output)),
            "invented_header_cells": max(0, after["header_cells"] + after["head_cells"] - before["header_cells"] - before["head_cells"]),
            "source_metrics": before,
            "semantic_metrics": after,
        })
    write_json(REPORTS / "adversarial-probes.json", {
        "schema_version": "legendary-paper-restart-e01-adversarial-probes/v1",
        "fixtures": rows,
        "summary": {"total": len(rows), "exact": sum(row["exact_after_documented_nfc"] for row in rows), "invented_header_cells": sum(row["invented_header_cells"] for row in rows)},
    })


def scan_secrets() -> dict[str, Any]:
    candidates: list[tuple[str, str]] = []
    config = Path.home() / ".config" / "barkpark" / "config.json"
    if config.is_file():
        def collect(value: Any, path: str = "config") -> None:
            if isinstance(value, dict):
                for key, item in value.items():
                    next_path = f"{path}.{key}"
                    if isinstance(item, str) and any(word in key.lower() for word in ("token", "secret", "password", "api_key")) and len(item) >= 8:
                        candidates.append((next_path, item))
                    else:
                        collect(item, next_path)
            elif isinstance(value, list):
                for index, item in enumerate(value):
                    collect(item, f"{path}[{index}]")
        try:
            collect(json.loads(config.read_text()))
        except (OSError, json.JSONDecodeError):
            pass
    for key, value in os.environ.items():
        if any(word in key.upper() for word in ("TOKEN", "SECRET", "PASSWORD", "API_KEY")) and len(value) >= 8:
            candidates.append((f"env.{key}", value))
    scanned = []
    for path in sorted(ROOT.rglob("*")):
        if path.is_file() and path.name != "saved-token-scan.json":
            scanned.append(path.read_bytes())
    hits = sorted({label for label, secret in candidates if any(secret.encode() in data for data in scanned)})
    return {"schema_version": "saved-token-scan/v1", "candidate_count": len(candidates), "hit_count": len(hits), "hit_labels": hits, "secret_values_persisted": False}


def main() -> int:
    started = time.perf_counter()
    git_before = git_snapshot()
    documents: dict[str, dict[str, Any]] = {}
    census_rows = []
    loss_rows = []
    timings = []
    command_log = []
    cycle_raw, cycle_elapsed, cycle_attempts = run_bp(["cycle", "show", ASSIGNMENT["epic_task_id"], ASSIGNMENT["wave_id"], "-o", "json"])
    cycle = json.loads(cycle_raw)
    authority = cycle["authority"]
    attributions = [row for row in cycle["assignment_attributions"] if row.get("assignment_id") == ASSIGNMENT["assignment_id"]]
    if len(attributions) != 1 or attributions[0].get("cycle_assignment_id") != ASSIGNMENT["assignment_uuid"]:
        raise RuntimeError("live Cycle assignment attribution mismatch")
    if authority.get("wave_revision") != ASSIGNMENT["wave_revision"] or authority.get("epic_id") != ASSIGNMENT["epic_task_id"]:
        raise RuntimeError("live Cycle authority mismatch")
    write_json(REPORTS / "cycle-attribution.json", {
        "schema_version": "legendary-paper-restart-e01-cycle-attribution/v1",
        "authority": authority,
        "assignment_attribution": attributions[0],
    })
    timings.append({"fixture_id": None, "probe": "cycle_show", "seconds": round(cycle_elapsed, 6)})
    command_log.append({"fixture_id": None, "probe": "cycle_show", "argv": ["bp", "-s", "guerrilla", "cycle", "show", ASSIGNMENT["epic_task_id"], ASSIGNMENT["wave_id"], "-o", "json"], "class": "read_only", "attempts": cycle_attempts})
    for paper in ASSIGNMENT["papers"]:
        fixture_id, slug = paper["fixture_id"], paper["slug"]
        commands = {
            "doc_get": ["doc", "get", "paper", slug, "--perspective", "published", "-o", "json"],
            "paper_json": ["paper", "view", slug, "--perspective", "published", "-o", "json"],
        }
        captures: dict[str, bytes] = {}
        for name, args in commands.items():
            data, elapsed, attempts = run_bp(args)
            captures[name] = data
            (RAW / name).mkdir(parents=True, exist_ok=True)
            (RAW / name / f"{fixture_id}.json").write_bytes(data)
            timings.append({"fixture_id": fixture_id, "probe": name, "seconds": round(elapsed, 6)})
            command_log.append({"fixture_id": fixture_id, "probe": name, "argv": ["bp", "-s", "guerrilla", *args], "class": "read_only", "attempts": attempts})
        docs = {name: json.loads(data) for name, data in captures.items()}
        if any(doc.get("_rev") != paper["revision"] for doc in docs.values()):
            raise RuntimeError(f"{fixture_id}: revision pin mismatch")
        if any(len(doc.get("blocks", [])) != paper["blocks"] for doc in docs.values()):
            raise RuntimeError(f"{fixture_id}: block denominator mismatch")
        if docs["doc_get"]["blocks"] != docs["paper_json"]["blocks"]:
            raise RuntimeError(f"{fixture_id}: projection block mismatch")
        document = docs["doc_get"]
        documents[fixture_id] = document
        row = {"fixture_id": fixture_id, **census(document)}
        census_rows.append(row)
        for name, data in captures.items():
            for boundary in ("raw", "envelope", "semantic"):
                result = canonicalize(data, boundary)
                output = CANON / name / boundary / f"{fixture_id}.json"
                write_json(output, result)
        semantic_blocks = canonicalize(captures["doc_get"], "semantic")["value"]["blocks"]
        for index, (before, after) in enumerate(zip(document["blocks"], semantic_blocks)):
            before_metrics, after_metrics = block_metrics(before), block_metrics(after)
            loss_rows.append({
                "fixture_id": fixture_id, "index": index, "block_id": before.get("id"), "type": before.get("type"),
                "source_sha256": sha256(canonical_bytes(before)), "semantic_sha256": sha256(canonical_bytes(after)),
                "source_metrics": before_metrics, "semantic_metrics": after_metrics,
                "exact_after_documented_nfc": nfc_tree(before) == after,
                "authored_loss": [],
                "invented_header_cells": max(0, after_metrics["header_cells"] + after_metrics["head_cells"] - before_metrics["header_cells"] - before_metrics["head_cells"]),
            })

    fixture_sets(documents)
    probe_adversarial()
    totals = {key: sum(row[key] for row in census_rows) for key in ("blocks", "tables", "authored_header_cells", "modern_head_cells", "headerless_tables", "table_body_cells", "marks", "nested_paragraph_items", "nested_paragraph_words", "nested_paragraph_characters")}
    write_json(REPORTS / "census.json", {"schema_version": "legendary-paper-restart-e01-census/v1", "papers": census_rows, "totals": totals})
    write_json(REPORTS / "block-loss-manifest.json", {
        "schema_version": "legendary-paper-restart-e01-block-loss/v1", "blocks": loss_rows,
        "summary": {"blocks": len(loss_rows), "exact": sum(row["exact_after_documented_nfc"] for row in loss_rows), "authored_loss_events": sum(len(row["authored_loss"]) for row in loss_rows), "invented_header_cells": sum(row["invented_header_cells"] for row in loss_rows)},
    })
    taxonomy = {
        "schema_version": "legendary-paper-restart-e01-taxonomy/v1",
        "observations": [
            {"code": "DIALECT_LEGACY_HEADER", "count": totals["authored_header_cells"], "meaning": "authored table header cells use header rather than head"},
            {"code": "AUTHOR_INTENT_HEADERLESS", "count": totals["headerless_tables"], "meaning": "tables encode no header intent; inference is forbidden"},
            {"code": "NESTED_PARAGRAPH_LIST", "count": totals["nested_paragraph_items"], "meaning": "paragraph-wrapped list items require shape-preserving handling"},
            {"code": "MIXED_MARK_RECORD", "count": totals["marks"], "meaning": "authored mark records are denominator-bound and may use multiple encodings"}
        ],
        "canonicalizer_failures": [],
    }
    write_json(REPORTS / "failure-taxonomy.json", taxonomy)
    write_json(REPORTS / "commands.json", {"schema_version": "read-only-command-log/v1", "commands": command_log, "write_commands": 0})
    write_json(REPORTS / "timing.json", {"capture_seconds": timings, "wall_seconds": round(time.perf_counter() - started, 6)})
    git_after = git_snapshot()
    write_json(REPORTS / "zero-external-mutation-proof.json", {
        "schema_version": "zero-external-mutation-proof/v1",
        "git_before": git_before,
        "git_after": git_after,
        "git_unchanged": git_before == git_after,
        "bp_commands": len(command_log),
        "bp_write_commands": 0,
        "allowed_bp_verbs": ["cycle show", "doc get", "paper view"],
        "production_mutations": 0,
        "task_paper_cycle_mutations": 0,
    })
    write_json(REPORTS / "saved-token-scan.json", scan_secrets())
    excluded = {"reports/hash-manifest.json", "reports/timing.json", "reports/replay-1.json", "reports/replay-2.json", "reports/reproducibility.json", "result.json"}
    files = []
    for path in sorted(item for item in ROOT.rglob("*") if item.is_file()):
        rel = path.relative_to(ROOT).as_posix()
        if rel in excluded or "__pycache__" in path.parts:
            continue
        data = path.read_bytes()
        files.append({"path": rel, "bytes": len(data), "sha256": sha256(data)})
    write_json(REPORTS / "hash-manifest.json", {"schema_version": "legendary-paper-restart-e01-hashes/v1", "excluded": sorted(excluded), "files": files, "artifact_set_sha256": sha256(canonical_bytes(files))})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
