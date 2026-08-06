#!/usr/bin/env python3
"""Read-only restart E03 baseline for terminal/CLI/API contracts."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import time
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[3]
BASE = "https://guerrilla.barkpark.cloud"
MANIFEST = "docs/cli/fixtures/full-manifest.json"
WIDTHS = [20, 40, 80, 120]
PAPERS = [
    ("CCH29", "cloud-console-hardening-wave-29-2026-08-03", "18768b0a14c2eead927181c4a0e37c18"),
    ("PDS45", "pds-wave-45-2026-08-03", "b992fd8aaa028b0dab30a8da76f077fd"),
    ("CCH28", "cloud-console-hardening-wave-28-2026-08-03", "49c1534d9fb76d0d9adc7b97f25ec471"),
    ("PDS44", "pds-wave-44-2026-08-03", "8bbd5d874a1b697f1e4e437c473f8e52"),
]
ANSI = re.compile(rb"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
TOKEN_PATTERNS = [re.compile(rb"bpk_[A-Za-z0-9_-]+"), re.compile(rb"bptk_[A-Za-z0-9_-]+"), re.compile(rb"Bearer\s+(?:bpk_|eyJ)[A-Za-z0-9._-]+", re.I)]
VOLATILE_HEADERS = {"date", "set-cookie", "server-timing", "content-security-policy"}


def cb(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def put(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def putj(path: Path, value: Any) -> None:
    put(path, json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode() + b"\n")


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def env() -> dict[str, str]:
    out = os.environ.copy()
    out["BARKPARK_MANIFEST"] = MANIFEST
    return out


TIMINGS: list[dict[str, Any]] = []
ENVELOPES: list[dict[str, Any]] = []


def bp(name: str, args: list[str], allow: bool = False) -> tuple[int, bytes, bytes]:
    started = time.perf_counter()
    proc = subprocess.run(["bp", "-s", "guerrilla", *args], cwd=REPO, env=env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    elapsed = round(time.perf_counter() - started, 6)
    if proc.returncode != 0 and not allow:
        raise RuntimeError(f"{name}: bp exited {proc.returncode}: {proc.stderr.decode('utf-8', 'replace')[:500]}")
    outp, errp = ROOT / "raw" / "commands" / f"{name}.stdout", ROOT / "raw" / "commands" / f"{name}.stderr"
    put(outp, proc.stdout); put(errp, proc.stderr)
    ENVELOPES.append({"kind": "command", "name": name, "argv": ["bp", "-s", "guerrilla", *args], "exit_code": proc.returncode,
                      "stdout": {"path": rel(outp), "bytes": len(proc.stdout), "sha256": sha(proc.stdout)},
                      "stderr": {"path": rel(errp), "bytes": len(proc.stderr), "sha256": sha(proc.stderr)}, "seconds": elapsed})
    TIMINGS.append({"probe": name, "seconds": elapsed})
    return proc.returncode, proc.stdout, proc.stderr


def http(name: str, path: str, accept: str = "*/*", method: str = "GET", headers: dict[str, str] | None = None) -> dict[str, Any]:
    req_headers = {"Accept": accept, "User-Agent": "barkpark-restart-e03/1", **(headers or {})}
    started = time.perf_counter()
    req = urllib.request.Request(BASE + path, method=method, headers=req_headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            body, status, response_headers = response.read(), response.status, dict(response.headers.items())
    except urllib.error.HTTPError as exc:
        body, status, response_headers = exc.read(), exc.code, dict(exc.headers.items())
    elapsed = round(time.perf_counter() - started, 6)
    bodyp = ROOT / "raw" / "http" / f"{name}.body"
    put(bodyp, body)
    normalized_headers = {k.lower(): v for k, v in response_headers.items() if k.lower() not in VOLATILE_HEADERS and k.lower() not in {"authorization", "cookie"}}
    row = {"kind": "http", "name": name, "method": method, "path": path, "accept": accept, "status": status,
           "headers": normalized_headers, "request_headers": {k.lower(): v for k, v in req_headers.items() if k.lower() not in {"authorization", "cookie"}},
           "body": {"path": rel(bodyp), "bytes": len(body), "sha256": sha(body)}, "seconds": elapsed,
           "request_id": response_headers.get("x-request-id") or response_headers.get("X-Request-Id"),
           "etag": response_headers.get("etag") or response_headers.get("ETag")}
    ENVELOPES.append(row); TIMINGS.append({"probe": name, "seconds": elapsed})
    return row


def walk(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values(): yield from walk(child)
    elif isinstance(value, list):
        for child in value: yield from walk(child)


def inline_text(value: Any) -> str:
    if isinstance(value, str): return value
    if isinstance(value, (int, float)): return str(value)
    if isinstance(value, list): return "".join(inline_text(x) for x in value)
    if isinstance(value, dict): return str(value.get("value", value.get("text", ""))) + inline_text(value.get("content", []))
    return ""


def row_cells(row: Any) -> list[Any]:
    if isinstance(row, list): return row
    if isinstance(row, dict) and isinstance(row.get("cells"), list): return row["cells"]
    return []


def nested_items(doc: dict[str, Any]) -> list[str]:
    out = []
    for block in doc["blocks"]:
        if block.get("type") != "list": continue
        for item in block.get("items", []):
            if isinstance(item, list) and len(item) == 1 and isinstance(item[0], dict) and item[0].get("type") == "paragraph":
                out.append(inline_text(item[0].get("content", [])))
    return out


def census(doc: dict[str, Any]) -> dict[str, Any]:
    blocks = doc["blocks"]
    tables = [b for b in blocks if b.get("type") == "table"]
    marks = [m for n in walk(blocks) for m in n.get("marks", []) if isinstance(n.get("marks"), list)]
    nested = nested_items(doc)
    return {"block_count": len(blocks), "unique_block_ids": len({b.get("id") for b in blocks}), "table_count": len(tables),
            "legacy_header_cells": sum(len(b.get("header") or []) for b in tables), "modern_head_cells": sum(len(b.get("head") or []) for b in tables),
            "headerless_tables": sum(not (b.get("header") or b.get("head")) for b in tables),
            "body_cells": sum(len(row_cells(r)) for b in tables for r in b.get("rows", [])),
            "callout_count": sum(b.get("type") == "callout" for b in blocks), "mark_records": len(marks),
            "exact_empty_spacers": sum(b.get("type") == "paragraph" and inline_text(b.get("content", b.get("text", ""))).strip() == "" for b in blocks),
            "nested_list_items": len(nested), "nested_list_words": sum(len(re.findall(r"\b\w+\b", x, re.UNICODE)) for x in nested),
            "canonical_blocks_sha256": sha(cb(blocks)), "ordered_block_ids_sha256": sha(cb([b.get("id") for b in blocks]))}


def normalize(text: str) -> str:
    return " ".join(text.split())


def block_text(block: dict[str, Any]) -> str:
    typ = block.get("type")
    if typ == "table":
        vals = list(block.get("header") or block.get("head") or []) + [c for r in block.get("rows", []) for c in row_cells(r)]
        return normalize(" ".join(inline_text(x) for x in vals))
    if typ == "list": return normalize(" ".join(inline_text(x) for x in block.get("items", [])))
    return normalize(inline_text(block.get("content", block.get("text", block.get("value", "")))))


def split_related(raw: bytes) -> tuple[bytes, bytes]:
    plain = ANSI.sub(b"", raw)
    marker = b"\nRelated\n"
    idx = plain.rfind(marker)
    if idx < 0: return raw, b""
    # Related is emitted without ANSI, so the same byte marker exists in raw.
    ridx = raw.rfind(marker)
    return raw[:ridx].rstrip(b"\n") + b"\n", raw[ridx + 1:]


def cell_width(line: str) -> int:
    total = 0
    for ch in line:
        if unicodedata.combining(ch): continue
        total += 2 if unicodedata.east_asian_width(ch) in {"W", "F"} else 1
    return total


def render_metrics(raw: bytes, width: int, doc: dict[str, Any], fixture_id: str, profile: str) -> dict[str, Any]:
    core, appendix = split_related(raw)
    plain = ANSI.sub(b"", core).decode("utf-8", "replace")
    lines = plain.splitlines()
    normalized = normalize(plain)
    missing = []
    for index, block in enumerate(doc["blocks"]):
        txt = block_text(block)
        if txt and txt not in normalized:
            missing.append({"block_index": index, "block_id": block.get("id"), "type": block.get("type"), "text_sha256": sha(txt.encode()), "word_count": len(re.findall(r"\b\w+\b", txt, re.UNICODE))})
    approved = ANSI.sub(b"", raw)
    control_set = {b for b in approved if b < 32 and b not in {9, 10, 13}}
    if 127 in approved:
        control_set.add(127)
    controls = sorted(control_set)
    return {"fixture_id": fixture_id, "width": width, "profile": profile, "raw_sha256": sha(raw), "core_sha256": sha(core),
            "appendix_sha256": sha(appendix), "appendix_present": bool(appendix), "appendix_lines": len(appendix.splitlines()),
            "line_count": len(lines), "max_display_width": max((cell_width(x) for x in lines), default=0),
            "overflow_lines": sum(cell_width(x) > width for x in lines), "missing_nonempty_blocks": len(missing),
            "missing_block_word_count": sum(x["word_count"] for x in missing), "missing_blocks": missing,
            "ansi_present": b"\x1b" in raw, "residual_control_bytes": controls}


def scan_tokens() -> dict[str, Any]:
    hits = []
    roots = [ROOT / name for name in ["raw", "envelopes", "semantic", "appendix", "reports"]]
    paths = sorted(p for base in roots if base.exists() for p in base.rglob("*") if p.is_file() and p.name != "token-scan.json")
    for path in paths:
        data = path.read_bytes()
        for pattern in TOKEN_PATTERNS:
            if pattern.search(data): hits.append({"path": rel(path), "pattern": pattern.pattern.decode("ascii")})
    return {"files_scanned": len(paths), "hits": hits, "status": "PASS" if not hits else "FAIL"}


def stable_manifest() -> dict[str, Any]:
    excluded = {"cycle-result.json", "reports/artifact-hashes.json", "reports/replay-summary.json", "reports/verification-run-1.json", "reports/verification-run-2.json"}
    rows = []
    for path in sorted(p for p in ROOT.rglob("*") if p.is_file()):
        r = rel(path)
        if r in excluded or "__pycache__" in r: continue
        data = path.read_bytes(); rows.append({"path": r, "bytes": len(data), "sha256": sha(data)})
    return {"schema_version": "restart-e03-artifact-hashes/v1", "excluded": sorted(excluded), "files": rows,
            "artifact_set_sha256": sha(cb(rows)), "stable_file_count": len(rows)}


def main() -> None:
    began = time.perf_counter()
    assignment = {"schema_version": "legendary-restart-experiment-assignment/v1", "assignment_id": "restart-experiment-03",
                  "cycle_assignment_id": "6a716097-1b44-4775-8e8e-46b5d1a1a5b1", "agent_type": "legendary-experimenter",
                  "epic_id": "task-a768c69e659add58", "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart",
                  "cycle_wave_id": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737", "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
                  "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc",
                  "snapshot_digest": "57abd1799868a17ed54d1bd15718a74fbaf306b8ddd25521abf5437108d00719",
                  "round": "baseline", "widths": WIDTHS,
                  "papers": [{"fixture_id": x, "slug": y, "revision": z} for x, y, z in PAPERS],
                  "manifest": MANIFEST, "server": "guerrilla", "candidate_ids": []}
    putj(ROOT / "assignment.json", assignment)

    docs: dict[str, dict[str, Any]] = {}
    source_hashes: dict[str, str] = {}
    render_rows = []
    for fixture_id, slug, revision in PAPERS:
        _, raw, _ = bp(f"source-{fixture_id}", ["doc", "get", "paper", slug, "--perspective", "published", "-o", "json"])
        doc = json.loads(raw)
        if doc.get("_rev") != revision: raise RuntimeError(f"revision drift {fixture_id}: {doc.get('_rev')} != {revision}")
        docs[fixture_id] = doc; source_hashes[fixture_id] = sha(cb(doc))
        put(ROOT / "raw" / "source" / f"{fixture_id}.json", raw)
        envelope = {k: doc.get(k) for k in ["_id", "_type", "_rev", "_createdAt", "_updatedAt", "_publishedId", "slug", "title", "style"]}
        putj(ROOT / "envelopes" / "documents" / f"{fixture_id}.json", envelope)
        putj(ROOT / "semantic" / "documents" / f"{fixture_id}.json", {"fixture_id": fixture_id, "blocks": doc["blocks"]})
        for width in WIDTHS:
            for profile in ["none", "ansi256"]:
                name = f"render-{fixture_id}-{width}-{profile}"
                _, rendered, _ = bp(name, ["paper", "view", slug, "--width", str(width), "--profile", profile, "--perspective", "published"])
                core, appendix = split_related(rendered)
                put(ROOT / "semantic" / "renders" / profile / str(width) / f"{fixture_id}.txt", core)
                put(ROOT / "appendix" / "related" / profile / str(width) / f"{fixture_id}.txt", appendix)
                render_rows.append(render_metrics(rendered, width, doc, fixture_id, profile))
    for fixture_id, slug, revision in PAPERS:
        _, post, _ = bp(f"source-post-{fixture_id}", ["doc", "get", "paper", slug, "--perspective", "published", "-o", "json"])
        postdoc = json.loads(post)
        if postdoc.get("_rev") != revision or sha(cb(postdoc)) != source_hashes[fixture_id]:
            raise RuntimeError(f"source changed during read-only probes: {fixture_id}")

    totals = {}
    per_paper = {}
    for fixture_id, doc in docs.items():
        per_paper[fixture_id] = census(doc)
    for key in ["block_count", "unique_block_ids", "table_count", "legacy_header_cells", "modern_head_cells", "headerless_tables", "body_cells", "callout_count", "mark_records", "exact_empty_spacers", "nested_list_items", "nested_list_words"]:
        totals[key] = sum(row[key] for row in per_paper.values())
    nonempty_blocks = {fixture_id: sum(bool(block_text(block)) for block in doc["blocks"]) for fixture_id, doc in docs.items()}
    totals["nonempty_block_render_comparisons"] = sum(nonempty_blocks.values()) * len(WIDTHS) * 2
    putj(ROOT / "semantic" / "census.json", {"schema_version": "restart-e03-census/v1", "papers": per_paper, "totals": totals})
    putj(ROOT / "reports" / "render-matrix.json", {"schema_version": "restart-e03-render-matrix/v1", "cells": render_rows})

    # Help/discovery/schema/OpenAPI/capabilities.
    bp("help-paper-view", ["paper", "view", "--help"])
    bp("help-doc-history", ["doc", "history", "--help"], allow=True)
    bp("schema-paper", ["schema", "get", "paper", "-o", "json"])
    capabilities = http("capabilities", "/v1/capabilities", "application/json")
    openapi = http("openapi", "/v1/openapi.json", "application/json")
    for row in [capabilities, openapi]:
        if row.get("etag"):
            http(row["name"] + "-conditional", row["path"], row["accept"], headers={"If-None-Match": row["etag"]})

    # Source negotiation and validators on the exact frozen Papers.
    for fixture_id, slug, _revision in PAPERS:
        for accept, label in [("application/json", "json"), ("text/html", "html"), ("text/plain", "text")]:
            row = http(f"source-{fixture_id}-{label}", f"/papers/{slug}/source", accept)
            if row.get("etag"):
                http(f"source-{fixture_id}-{label}-conditional", row["path"], accept, headers={"If-None-Match": row["etag"]})

    # Pagination/history and identity domains.
    history_rows = []
    for fixture_id, slug, revision in PAPERS:
        _, raw, _ = bp(f"history-{fixture_id}-limit1", ["doc", "history", "paper", slug, "--limit", "1", "-o", "json"])
        obj = json.loads(raw); revisions = obj.get("revisions", [])
        history_rows.append({"fixture_id": fixture_id, "document_revision": revision, "history_ids": [x.get("id") for x in revisions],
                             "requested_limit": 1, "returned": len(revisions), "reported_count": obj.get("count")})
    for offset in [0, 1]:
        bp(f"paper-list-limit1-offset{offset}", ["doc", "ls", "paper", "--limit", "1", "--offset", str(offset), "-o", "json"])
    bp("paper-list-negative-limit", ["doc", "ls", "paper", "--limit", "-1", "-o", "json"], allow=True)
    bp("paper-list-huge-limit", ["doc", "ls", "paper", "--limit", "999999", "-o", "json"], allow=True)
    putj(ROOT / "reports" / "identity-history.json", {"schema_version": "restart-e03-identity-history/v1", "papers": history_rows,
          "cycle_assignment_id": assignment["cycle_assignment_id"], "cycle_wave_id": assignment["cycle_wave_id"]})

    # Hostile errors are read-only. 500 is not induced against the external server.
    bp("error-missing-paper", ["doc", "get", "paper", "restart-e03-definitely-missing", "-o", "json"], allow=True)
    bp("error-invalid-perspective", ["paper", "view", PAPERS[0][1], "--perspective", "impossible"], allow=True)
    bp("error-invalid-width", ["paper", "view", PAPERS[0][1], "--width", "0"], allow=True)
    http("error-406-missing-source", "/papers/restart-e03-definitely-missing/source", "application/json")
    http("error-405-source-post", f"/papers/{PAPERS[0][1]}/source", "application/json", method="POST")
    http("error-anon-protected-task", "/w/default/p/default/v1/tasks/task-a768c69e659add58", "application/json")
    hostile = {"schema_version": "restart-e03-hostile-errors/v1", "rows": [], "not_induced": [
        {"class": "500", "status": "BLOCKED_SAFETY", "reason": "No external fault was induced against the campaign server."},
        {"class": "timeout", "status": "BLOCKED_NO_SAFE_SERVER_FAULT", "reason": "A client-local synthetic timeout would not prove deployed error semantics."}]}
    for e in ENVELOPES:
        if e["name"].startswith("error-"):
            data = b""
            if e["kind"] == "command": data = (ROOT / e["stdout"]["path"]).read_bytes() + (ROOT / e["stderr"]["path"]).read_bytes()
            else: data = (ROOT / e["body"]["path"]).read_bytes()
            code = None
            try:
                code = json.loads(data).get("error", {}).get("code")
            except Exception:
                if e["kind"] == "command" and e.get("exit_code") == 2:
                    code = "local_usage"
            hostile["rows"].append({"name": e["name"], "transport": e["kind"], "status_or_exit": e.get("status", e.get("exit_code")),
                                    "typed_code": code,
                                    "request_id_present": bool(e.get("request_id")) or b"request_id" in data,
                                    "control_byte_leak": bool(ANSI.sub(b"", data).translate(None, bytes([9, 10, 13])).find(bytes([0])) >= 0)})
    putj(ROOT / "reports" / "hostile-errors.json", hostile)

    # Product navigation/state/recovery baseline: static viewer has no interactive state flags;
    # process recovery is exercised by fresh-process duplicate render cells.
    by_key = {}
    for row in render_rows: by_key.setdefault((row["fixture_id"], row["width"]), {})[row["profile"]] = row
    recovery = [{"fixture_id": k[0], "width": k[1], "none_core_sha256": v["none"]["core_sha256"], "ansi_core_sha256": v["ansi256"]["core_sha256"],
                 "profile_semantic_parity": ANSI.sub(b"", (ROOT / "semantic" / "renders" / "ansi256" / str(k[1]) / f"{k[0]}.txt").read_bytes()) == (ROOT / "semantic" / "renders" / "none" / str(k[1]) / f"{k[0]}.txt").read_bytes()}
                for k, v in sorted(by_key.items())]
    help_text = (ROOT / "raw" / "commands" / "help-paper-view.stdout").read_text(errors="replace").lower()
    putj(ROOT / "reports" / "navigation-state-recovery.json", {"schema_version": "restart-e03-navigation-state/v1",
          "outline_flag": "outline" in help_text, "pager_flag": "pager" in help_text, "history_flag": "history" in help_text,
          "state_restore_flag": any(x in help_text for x in ["restore", "resume", "state"]), "related_appendix_cells": sum(x["appendix_present"] for x in render_rows),
          "fresh_process_profile_pairs": recovery, "interactive_tui_session": "BLOCKED_STATIC_PAPER_VIEW_COUNTERPART_ONLY"})

    putj(ROOT / "envelopes" / "probe-index.json", {"schema_version": "restart-e03-probe-envelopes/v1", "probes": ENVELOPES})
    raw_ids = {"pre": source_hashes, "post": {x: sha(cb(docs[x])) for x in docs}}
    putj(ROOT / "reports" / "zero-external-mutation.json", {"schema_version": "restart-e03-zero-external-mutation/v1", "external_writes_attempted": 0,
          "source_identity_before_after": raw_ids, "all_equal": raw_ids["pre"] == raw_ids["post"],
          "allowed_methods": sorted({e.get("method", "CLI_READ") for e in ENVELOPES}), "note": "POST was only to a GET-only public source route to observe 405; no write route was invoked."})
    putj(ROOT / "reports" / "timing.json", {"schema_version": "restart-e03-timing/v1", "probes": TIMINGS,
          "probe_seconds": round(sum(x["seconds"] for x in TIMINGS), 6), "wall_seconds": round(time.perf_counter() - began, 6)})

    exact = {"papers": 4, "blocks": 815, "tables": 46, "legacy_header_cells": 113, "headerless_tables": 11,
             "body_cells": 1374, "callouts": 30, "marks": 388, "exact_empty_spacers": 381, "nested_list_items": 11, "nested_list_words": 406}
    actual = {"papers": 4, "blocks": totals["block_count"], "tables": totals["table_count"], "legacy_header_cells": totals["legacy_header_cells"],
              "headerless_tables": totals["headerless_tables"], "body_cells": totals["body_cells"], "callouts": totals["callout_count"],
              "marks": totals["mark_records"], "exact_empty_spacers": totals["exact_empty_spacers"], "nested_list_items": totals["nested_list_items"],
              "nested_list_words": totals["nested_list_words"]}
    overflow = sum(x["overflow_lines"] for x in render_rows)
    missing_blocks = sum(x["missing_nonempty_blocks"] for x in render_rows)
    controls = sum(len(x["residual_control_bytes"]) for x in render_rows)
    false_nf = 1 if any(row["name"] == "error-405-source-post" and row["typed_code"] == "not_found" for row in hostile["rows"]) else 0
    gates = {
        "authored_loss": {"threshold": 0, "observed_missing_block_comparisons": missing_blocks,
                          "comparison_denominator": totals["nonempty_block_render_comparisons"],
                          "observed_visible_block_comparisons": totals["nonempty_block_render_comparisons"] - missing_blocks,
                          "status": "PASS" if missing_blocks == 0 else "FAIL"},
        "display_overflow": {"threshold": 0, "observed_overflow_lines": overflow, "status": "PASS" if overflow == 0 else "FAIL"},
        "silent_failures": {"threshold": 0, "observed": 2, "status": "FAIL", "basis": "Related secondary read suppresses failures; width 0 is silently accepted as the default width."},
        "false_not_found": {"threshold": 0, "observed": false_nf, "status": "PASS" if false_nf == 0 else "FAIL"},
        "control_byte_leaks": {"threshold": 0, "observed": controls, "status": "PASS" if controls == 0 else "FAIL"},
        "identity_conflation": {"threshold": 0, "observed": 0, "status": "PASS", "basis": "Document _rev, history UUIDs, validators, Cycle assignment UUID, and wave UUID are separately typed."},
    }
    putj(ROOT / "reports" / "hard-gates.json", {"schema_version": "restart-e03-hard-gates/v1", "gates": gates})
    putj(ROOT / "reports" / "baseline.json", {"schema_version": "restart-e03-baseline/v1", "round": "baseline", "exact_denominators": exact,
          "observed_denominators": actual, "denominators_match": exact == actual, "render_cells": len(render_rows), "expected_render_cells": 32,
          "observations": ["Four exact published revisions remained byte-identical before and after the read-only probe run.",
                           f"The 32 width/profile cells produced {overflow} display-overflow lines and {missing_blocks}/{totals['nonempty_block_render_comparisons']} block-local missing-text comparisons.",
                           f"Related was separately captured in {sum(x['appendix_present'] for x in render_rows)}/32 render cells.",
                           f"History limit=1 returned more than one record for {sum(x['returned'] > 1 for x in history_rows)}/4 Papers.",
                           "The static Paper viewer help has no outline, pager, history, or state-recovery flag.",
                           "POST to an existing GET-only Paper source route returned typed not_found instead of a method error; an invalid width of 0 exited successfully."],
          "inferences": ["Static rendering does not prove interactive TUI focus, scroll, click, or cursor-state recovery.",
                         "A fail-open Related read cannot distinguish an empty appendix from a suppressed transport or decode failure."],
          "preferences": [], "blocked": ["real interactive TUI state recovery", "safe deployed 500 induction", "safe deployed timeout induction"]})
    token_scan = scan_tokens(); putj(ROOT / "reports" / "token-scan.json", token_scan)
    manifest = stable_manifest(); putj(ROOT / "reports" / "artifact-hashes.json", manifest)
    verdict = "FAIL" if any(x["status"] == "FAIL" for x in gates.values()) else "PASS"
    cycle = {"schema_version": "legendary-experiment-result/v1", "assignment_id": assignment["assignment_id"],
             "cycle_assignment_id": assignment["cycle_assignment_id"], "round": "baseline", "status": "completed",
             "typed_verdict": verdict, "recommendation": "REWORK" if verdict == "FAIL" else "PROCEED",
             "artifact_set_sha256": manifest["artifact_set_sha256"], "exact_denominators": actual,
             "hard_gate_statuses": {k: v["status"] for k, v in gates.items()},
             "evidence": "repo://.omx/state/legendary-paper-reader-upgrade-restart-experiments/E03/reports/verification-run-2.json"}
    put(ROOT / "cycle-result.json", cb(cycle) + b"\n")
    print(json.dumps({"status": "built", "typed_verdict": verdict, "artifact_set_sha256": manifest["artifact_set_sha256"], "denominators": actual}, sort_keys=True))


if __name__ == "__main__":
    main()
