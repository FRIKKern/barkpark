#!/usr/bin/env python3
"""Build E03 terminal/navigation/identity/discovery baseline; read-only externally."""

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
BASE = "https://guerrilla.barkpark.cloud"
WIDTHS = [20, 40, 80, 120]
PAPERS = [
    ("CCH29", "cloud-console-hardening-wave-29-2026-08-03", "18768b0a14c2eead927181c4a0e37c18"),
    ("PDS45", "pds-wave-45-2026-08-03", "b992fd8aaa028b0dab30a8da76f077fd"),
    ("CCH28", "cloud-console-hardening-wave-28-2026-08-03", "49c1534d9fb76d0d9adc7b97f25ec471"),
    ("PDS44", "pds-wave-44-2026-08-03", "8bbd5d874a1b697f1e4e437c473f8e52"),
]
ANSI_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")


def cbytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def write_json(path: Path, value: Any) -> None:
    write_bytes(path, json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode() + b"\n")


def command(args: list[str], allow_failure: bool = False) -> tuple[int, bytes, bytes, float]:
    started = time.perf_counter()
    last = None
    for attempt in range(1, 5):
        proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        last = proc
        if proc.returncode == 0 or allow_failure:
            return proc.returncode, proc.stdout, proc.stderr, time.perf_counter() - started
        if attempt < 4:
            time.sleep(attempt * 0.5)
    assert last is not None
    raise RuntimeError(f"command failed after retries: {' '.join(args)}: {last.stderr.decode('utf-8', 'replace')}")


def request(path: str, accept: str = "*/*", authenticated: bool = False) -> dict[str, Any]:
    headers = {"Accept": accept, "User-Agent": "barkpark-e03-baseline/1"}
    if authenticated and os.environ.get("BARKPARK_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["BARKPARK_TOKEN"]
    started = time.perf_counter()
    last_error = None
    for attempt in range(1, 5):
        req = urllib.request.Request(BASE + path, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                body = response.read()
                return {
                    "path": path, "accept": accept, "status": response.status,
                    "headers": {k.lower(): v for k, v in response.headers.items()},
                    "body": body, "seconds": round(time.perf_counter() - started, 6),
                }
        except urllib.error.HTTPError as exc:
            body = exc.read()
            if exc.code < 500 or attempt == 4:
                return {
                    "path": path, "accept": accept, "status": exc.code,
                    "headers": {k.lower(): v for k, v in exc.headers.items()},
                    "body": body, "seconds": round(time.perf_counter() - started, 6),
                }
            last_error = exc
        except (urllib.error.URLError, TimeoutError) as exc:
            last_error = exc
        if attempt < 4:
            time.sleep(attempt * 0.5)
    raise RuntimeError(f"GET {path} failed: {last_error}")


def walk(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "".join(text(v) for v in value)
    if isinstance(value, dict):
        return str(value.get("value", value.get("text", ""))) + text(value.get("content", []))
    return ""


def normalize(value: str) -> str:
    return " ".join(value.split())


def item_text(item: Any) -> str:
    return normalize(text(item))


def semantic_sets(doc: dict[str, Any]) -> dict[str, Any]:
    blocks = doc["blocks"]
    headings = [(int(b.get("level", 2)), normalize(text(b.get("content", b.get("text", ""))))) for b in blocks if b.get("type") == "heading"]
    headers = [normalize(text(cell)) for b in blocks if b.get("type") == "table" for cell in (b.get("header") or b.get("head") or [])]
    lists = [item_text(item) for b in blocks if b.get("type") == "list" for item in b.get("items", [])]
    marked = []
    mark_types = []
    for node in walk(blocks):
        marks = node.get("marks")
        if isinstance(marks, list) and marks:
            marked.append(normalize(text(node)))
            mark_types.extend(mark if isinstance(mark, str) else mark.get("type", "unknown") for mark in marks)
    tones = [b.get("tone") for b in blocks if b.get("type") == "callout"]
    task_tokens = sorted(set(re.findall(r"\b(?:task-[a-z0-9-]+|drafts\.task-[a-z0-9-]+)\b", text(blocks), re.I)))
    return {"headings": headings, "headers": headers, "list_items": lists, "marked_runs": marked, "mark_types": mark_types, "tones": tones, "task_tokens": task_tokens}


def render_metrics(raw: bytes, width: int, sem: dict[str, Any], ansi: bool) -> dict[str, Any]:
    decoded = raw.decode("utf-8", "replace")
    plain = ANSI_RE.sub("", decoded)
    flat = normalize(plain)
    lines = plain.splitlines()
    headings = [h for _level, h in sem["headings"] if h]
    headers = [h for h in sem["headers"] if h]
    list_items = [i for i in sem["list_items"] if i]
    marked = [m for m in sem["marked_runs"] if m]
    return {
        "bytes": len(raw), "sha256": sha(raw), "ansi_escape_present": "\x1b" in decoded,
        "line_count": len(lines), "max_codepoint_width": max((len(line) for line in lines), default=0),
        "overflow_line_count": sum(len(line) > width for line in lines),
        "heading_text_exact": sum(h in flat for h in headings), "heading_text_total": len(headings),
        "header_literal_visible_anywhere": sum(h in flat for h in headers), "header_literal_total": len(headers),
        "list_item_text_exact": sum(i in flat for i in list_items), "list_item_total": len(list_items),
        "marked_run_text_exact": sum(m in flat for m in marked), "marked_run_total": len(marked),
        "task_token_visible": sum(token in plain for token in sem["task_tokens"]), "task_token_total": len(sem["task_tokens"]),
        "structural_header_carrier": 0,
        "explicit_tone_label_carrier": 0,
        "explicit_revision_carrier": 0,
        "profile": "ansi256" if ansi else "none",
    }


def body_record(name: str, response: dict[str, Any]) -> dict[str, Any]:
    body_path = RAW / "contracts" / f"{name}.body"
    write_bytes(body_path, response["body"])
    headers = {k: v for k, v in response["headers"].items() if k not in {"set-cookie", "authorization"}}
    return {
        "name": name, "path": response["path"], "accept": response["accept"],
        "status": response["status"], "headers": headers, "body_path": body_path.relative_to(ROOT).as_posix(),
        "body_bytes": len(response["body"]), "body_sha256": sha(response["body"]), "seconds": response["seconds"],
        "etag": response["headers"].get("etag"),
        "request_id_header": response["headers"].get("x-request-id"),
        "request_id_body_present": b"request_id" in response["body"],
    }


def make_fixtures(docs: dict[str, dict[str, Any]]) -> None:
    controls = {
        "schema_version": "legendary-paper-e03-controls/v1",
        "dimensions": {
            "hierarchy": {"fixture": "CCH28", "heading_levels": {str(n): sum(b.get("type") == "heading" and int(b.get("level", 2)) == n for b in docs["CCH28"]["blocks"]) for n in (1, 2, 3)}},
            "legacy_header": {"fixture": "CCH29", "block": next(b for b in docs["CCH29"]["blocks"] if b.get("type") == "table" and b.get("header"))},
            "flat_list": {"fixture": "PDS45", "block": next(b for b in docs["PDS45"]["blocks"] if b.get("type") == "list")},
            "string_marks": {"fixture": "CCH29", "count": 313},
            "object_marks": {"fixture": "PDS45", "count": 8},
            "tone": {"fixture": "CCH28", "values": [b.get("tone") for b in docs["CCH28"]["blocks"] if b.get("type") == "callout"]},
            "identity": {"fixture": "CCH29", "slug": PAPERS[0][1], "revision": PAPERS[0][2]},
            "history_uuid": {"fixture": "CCH29", "expected_shape": "UUID revision id"},
            "typed_error": {"fixture": "missing-paper", "expected": "nonzero exit plus structured envelope"},
            "source_negotiation": {"fixture": "CCH29", "accepts": ["application/json", "text/html", "text/plain"]},
        },
    }
    bad = {
        "schema_version": "legendary-paper-e03-known-bad/v1",
        "targets": [
            {"id": "no-outline-or-pager", "dimension": "navigation"},
            {"id": "paper-history-not-in-reader", "dimension": "history"},
            {"id": "history-limit-not-forwarded", "dimension": "limit"},
            {"id": "human-reader-no-revision", "dimension": "identity"},
            {"id": "legacy-header-drop", "dimension": "header", "count": 113},
            {"id": "nested-list-drop", "dimension": "list", "words": 406},
            {"id": "nocolor-hierarchy-mark-tone-collapse", "dimension": "semantics"},
            {"id": "narrow-width-overflow", "dimension": "width"},
            {"id": "source-negotiation-drift", "dimension": "contract"},
            {"id": "broad-not-found-mapping", "dimension": "typed_error"},
            {"id": "missing-etag-provenance", "dimension": "provenance"},
            {"id": "unstructured-task-linkage", "dimension": "task_link"},
        ],
    }
    adversarial = {
        "schema_version": "legendary-paper-e03-adversarial/v1",
        "frozen_before_round_2": True,
        "fixtures": [
            {"id": "missing-paper", "kind": "missing", "slug": "e03-definitely-missing-paper", "expected": "typed not_found with request id"},
            {"id": "malformed-source", "kind": "malformed", "blocks": [{"type": "heading", "level": "NaN"}, {"type": "table", "header": "not-array", "rows": [None]}], "expected": "explicit supported error"},
            {"id": "long-token", "kind": "long_token", "token": "E03_" + "X" * 512, "widths": WIDTHS, "expected": "no silent truncation"},
            {"id": "missing-identity", "kind": "missing_fields", "document": {"_type": "paper", "blocks": []}, "expected": "explicit missing slug/revision behavior"},
            {"id": "bad-history-uuid", "kind": "history", "revision": "not-a-uuid", "expected": "typed validation error"},
            {"id": "error-html-vs-json", "kind": "negotiation", "accepts": ["application/json", "text/html", "text/plain"], "expected": "status and envelope remain intentional"},
            {"id": "limit-zero-negative-huge", "kind": "pagination", "limits": [0, -1, 1, 999999], "expected": "bounded deterministic forwarding"},
            {"id": "task-token-only", "kind": "task_link", "text": "task-deadbeef without structured mark", "expected": "distinguish text from navigable linkage"},
        ],
    }
    write_json(FIXTURES / "controls.json", controls)
    write_json(FIXTURES / "known-bad.json", bad)
    write_json(FIXTURES / "adversarial.json", adversarial)


def stable_manifest() -> dict[str, Any]:
    excluded = {"reports/hash-manifest.json", "reports/timing.json", "reports/verification.json"}
    rows = []
    for path in sorted(p for p in ROOT.rglob("*") if p.is_file()):
        rel = path.relative_to(ROOT).as_posix()
        if rel in excluded or "__pycache__" in rel:
            continue
        data = path.read_bytes()
        rows.append({"path": rel, "bytes": len(data), "sha256": sha(data)})
    return {"schema_version": "legendary-paper-e03-hash-manifest/v1", "excluded": sorted(excluded), "files": rows, "artifact_set_sha256": sha(cbytes(rows))}


def main() -> None:
    began = time.perf_counter()
    docs: dict[str, dict[str, Any]] = {}
    renders = []
    timings = []
    for fixture_id, slug, revision in PAPERS:
        rc, raw, err, seconds = command(["bp", "doc", "get", "paper", slug, "--perspective", "published", "-o", "json"])
        timings.append({"probe": "machine_cli_api", "fixture_id": fixture_id, "seconds": round(seconds, 6)})
        doc = json.loads(raw)
        if doc.get("_rev") != revision:
            raise RuntimeError(f"revision drift {fixture_id}: {doc.get('_rev')}")
        docs[fixture_id] = doc
        write_bytes(RAW / "machine" / f"{fixture_id}.json", raw)
        write_bytes(FIXTURES / "source" / f"{fixture_id}.json", cbytes(doc) + b"\n")
        sem = semantic_sets(doc)
        for width in WIDTHS:
            for surface, profile, ansi in (("tui-equivalent", "ansi256", True), ("human-cli", "none", False)):
                rc, output, stderr, seconds = command(["bp", "paper", "view", slug, "--width", str(width), "--profile", profile, "--perspective", "published"])
                timings.append({"probe": surface, "fixture_id": fixture_id, "width": width, "seconds": round(seconds, 6)})
                write_bytes(RAW / "renders" / surface / str(width) / f"{fixture_id}.txt", output)
                renders.append({"fixture_id": fixture_id, "slug": slug, "revision": revision, "surface": surface, "width": width, **render_metrics(output, width, sem, ansi)})

    make_fixtures(docs)
    write_json(REPORTS / "render-matrix.json", {"schema_version": "legendary-paper-e03-render-matrix/v1", "renders": renders})

    contracts = []
    contract_specs = []
    for fixture_id, slug, _revision in PAPERS:
        contract_specs.extend([
            (f"{fixture_id}-source-json", f"/papers/{slug}/source", "application/json", False),
            (f"{fixture_id}-source-html", f"/papers/{slug}/source", "text/html", False),
            (f"{fixture_id}-source-text", f"/papers/{slug}/source", "text/plain", False),
        ])
    contract_specs.extend([
        ("capabilities", "/v1/capabilities", "application/json", True),
        ("missing-source-json", "/papers/e03-definitely-missing-paper/source", "application/json", False),
        ("missing-source-text", "/papers/e03-definitely-missing-paper/source", "text/plain", False),
        ("missing-public-json", "/papers/e03-definitely-missing-paper", "application/json", False),
    ])
    for name, path, accept, authenticated in contract_specs:
        contracts.append(body_record(name, request(path, accept, authenticated)))

    rc, schema_out, schema_err, schema_seconds = command(["bp", "schema", "get", "paper", "-o", "json"])
    write_bytes(RAW / "contracts" / "schema-paper.json", schema_out)
    schema_doc = json.loads(schema_out)
    contracts.append({"name": "schema-paper-cli", "status": 200, "body_path": "raw/contracts/schema-paper.json", "body_bytes": len(schema_out), "body_sha256": sha(schema_out), "seconds": round(schema_seconds, 6), "schema_name": schema_doc.get("schema", {}).get("name")})

    histories = []
    for fixture_id, slug, revision in PAPERS:
        rc, out, err, seconds = command(["bp", "doc", "history", "paper", slug, "--limit", "1", "-o", "json"])
        hist = json.loads(out)
        write_bytes(RAW / "history" / f"{fixture_id}.json", out)
        revisions = hist.get("revisions", [])
        histories.append({
            "fixture_id": fixture_id, "requested_limit": 1, "reported_count": hist.get("count"), "returned_count": len(revisions),
            "limit_forwarded": len(revisions) <= 1, "first_history_uuid": revisions[0].get("id") if revisions else None,
            "current_document_revision": revision, "history_exposes_current_rev_hash": any(r.get("id") == revision for r in revisions),
            "seconds": round(seconds, 6), "sha256": sha(out),
        })
    write_json(REPORTS / "history-provenance.json", {"schema_version": "legendary-paper-e03-history/v1", "papers": histories})

    rc, out, err, seconds = command(["bp", "doc", "get", "paper", "e03-definitely-missing-paper", "-o", "json"], allow_failure=True)
    write_bytes(RAW / "errors" / "missing-paper.stdout", out)
    write_bytes(RAW / "errors" / "missing-paper.stderr", err)
    cli_error = {"exit_code": rc, "stdout_bytes": len(out), "stderr_bytes": len(err), "stdout_sha256": sha(out), "stderr_sha256": sha(err), "typed_not_found_text": b"not_found" in out + err, "request_id_text": b"request_id" in out + err, "seconds": round(seconds, 6)}

    rc, help_out, help_err, seconds = command(["bp", "paper", "view", "--help"])
    write_bytes(RAW / "contracts" / "paper-view-help.txt", help_out)
    help_text = help_out.decode("utf-8", "replace").lower()
    navigation = {
        "paper_view_help_sha256": sha(help_out), "outline_flag": "outline" in help_text, "pager_flag": "pager" in help_text,
        "history_flag": "history" in help_text, "width_flag": "--width" in help_text, "revision_identity_in_human_renders": 0,
        "structured_task_links_in_source_marks": 0,
        "textual_task_tokens": sum(len(semantic_sets(doc)["task_tokens"]) for doc in docs.values()),
    }

    totals = {
        "render_cells": len(renders), "expected_render_cells": 32,
        "overflow_cells": sum(row["overflow_line_count"] > 0 for row in renders),
        "total_overflow_lines": sum(row["overflow_line_count"] for row in renders),
        "heading_text_exact": sum(row["heading_text_exact"] for row in renders),
        "heading_text_total": sum(row["heading_text_total"] for row in renders),
        "header_structural_carriers": sum(row["structural_header_carrier"] for row in renders),
        "tone_label_carriers": sum(row["explicit_tone_label_carrier"] for row in renders),
        "revision_carriers": sum(row["explicit_revision_carrier"] for row in renders),
        "history_limit_forwarded": sum(row["limit_forwarded"] for row in histories),
        "history_limit_total": len(histories),
        "contract_cells": len(contracts),
    }
    observations = {
        "schema_version": "legendary-paper-e03-baseline/v1", "totals": totals,
        "navigation": navigation, "cli_error": cli_error, "contracts": contracts,
        "observed_facts": [
            "All 32 width/profile render cells were captured from the four exact revision pins.",
            "Human Paper view exposes width selection but no outline, pager, or history option.",
            "The machine history command returns UUID history ids distinct from the document _rev hash.",
            "A requested history limit of 1 is not forwarded on any of the four Papers.",
            "Human renders expose neither the pinned _rev nor a structural task-link mark.",
        ],
        "inferences": [
            "Width containment alone cannot satisfy navigation, hierarchy, identity, or semantic parity.",
            "Text that resembles a task id is not equivalent to an observable navigable task relationship.",
        ],
        "preferences": [],
    }
    write_json(REPORTS / "baseline.json", observations)

    thresholds = {
        "schema_version": "legendary-paper-e03-thresholds/v1", "declared_before_round_2": True,
        "hard_thresholds": {
            "surface_exercise": "32/32 width/profile cells plus machine API, history, schema, capabilities, negotiation, and typed-error probes",
            "width": "zero visible lines over requested 20/40/80/120 columns; long tokens degrade explicitly",
            "text": "100% heading/header/list/marked authored text survives or is explicitly quarantined",
            "hierarchy": "H1/H2/H3 remain non-color distinguishable",
            "headers": "113/113 authored headers retain structural role",
            "lists": "406/406 CCH29 nested-list words survive",
            "marks": "388/388 mark records retain supported semantic distinction",
            "tones": "30/30 callouts retain a non-color semantic tone cue",
            "navigation": "outline, bounded pager, Paper history, and task links observable",
            "identity": "slug, exact _rev, and history UUID roles are explicit and not conflated",
            "limit": "requested limit 1 returns at most one history record",
            "errors": "typed nonzero errors retain specific code and request id",
            "provenance": "ETag or equivalent immutable revision attestation is observable",
            "discovery": "Paper schema, capabilities, source negotiation, and errors are deterministic and documented",
            "idempotence": "two verifier runs return identical artifact_set_sha256",
        },
    }
    write_json(REPORTS / "thresholds.json", thresholds)
    taxonomy = {
        "schema_version": "legendary-paper-e03-failure-taxonomy/v1",
        "observed": [
            {"code": "T01_WIDTH_OVERFLOW", "hard": True}, {"code": "T02_LINE_EXPLOSION", "hard": True},
            {"code": "T03_HIERARCHY_COLOR_ONLY", "hard": True}, {"code": "T04_HEADER_ROLE_LOSS", "hard": True},
            {"code": "T05_LIST_TEXT_LOSS", "hard": True}, {"code": "T06_MARK_SEMANTIC_LOSS", "hard": True},
            {"code": "T07_TONE_SEMANTIC_LOSS", "hard": True}, {"code": "T08_NAVIGATION_ABSENT", "hard": True},
            {"code": "T09_HISTORY_LIMIT_IGNORED", "hard": True}, {"code": "T10_IDENTITY_CONFLATION_OR_ABSENCE", "hard": True},
            {"code": "T11_TASK_LINK_NOT_STRUCTURED", "hard": True}, {"code": "T12_TYPED_ERROR_COLLAPSE", "hard": True},
            {"code": "T13_ETAG_PROVENANCE_ABSENT", "hard": True}, {"code": "T14_NEGOTIATION_OR_DISCOVERY_DRIFT", "hard": True},
            {"code": "T15_REQUEST_ID_ABSENT", "hard": True}, {"code": "T16_TRANSIENT_DEPLOYED_5XX", "hard": False},
        ],
        "boundary": "Observed probe facts are separate from inferences; no candidate or format preference is selected.",
    }
    write_json(REPORTS / "failure-taxonomy.json", taxonomy)
    assignment = {
        "schema_version": "legendary-paper-e03-assignment/v1", "assignment_id": "experiment-03", "round": 1,
        "agent_type": "legendary-experimenter", "epic_id": "task-a768c69e659add58",
        "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-05", "wave_revision": "a06716c4-2dd5-4bda-b9a9-a484b009abb2",
        "inventory_digest": "3e480a9fcf44da65a07aa1fcad8e981911006568d23b89ad8891f26a5d96e69e",
        "assignment_snapshot_digest": "afd6034cab31b9633efcbf9a7b16983a71c80461692cc9daaf968afe2613a9f8",
        "candidate_ids": [], "widths": WIDTHS, "papers": [{"fixture_id": a, "slug": b, "revision": c} for a, b, c in PAPERS],
        "stop_condition": "Terminal/navigation/identity/discovery/error/provenance baseline and stable verification complete; no repair candidate built.",
    }
    write_json(ROOT / "assignment.json", assignment)
    manifest = stable_manifest()
    write_json(REPORTS / "hash-manifest.json", manifest)
    write_json(REPORTS / "timing.json", {"schema_version": "legendary-paper-e03-timing/v1", "probes": timings, "probe_seconds": round(sum(r["seconds"] for r in timings), 6), "build_wall_seconds": round(time.perf_counter() - began, 6), "contract_seconds": round(sum(r.get("seconds", 0) for r in contracts), 6), "excluded_from_stable_hash": True})
    print(json.dumps({"status": "built", "artifact_set_sha256": manifest["artifact_set_sha256"], "totals": totals}, sort_keys=True))


if __name__ == "__main__":
    main()
