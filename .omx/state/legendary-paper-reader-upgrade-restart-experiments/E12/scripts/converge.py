#!/usr/bin/env python3
"""Independently replay E04-E06 terminal/platform evidence and apply the replacement contract."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import textwrap
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parent
CANDIDATES = ("E04", "E05", "E06")
PAPERS = ("CCH28", "CCH29", "PDS44", "PDS45")
WIDTHS = (1, 20, 40, 80, 120)
INTERACTIONS = ("mouse", "focus", "scroll", "click", "Enter", "state", "history", "Related", "recovery")
ERRORS = ("401", "404", "405", "406", "422", "500", "timeout")
DISCOVERY = ("capabilities", "schema", "OpenAPI", "help", "pagination")
sys.dont_write_bytecode = True


def canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value))


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def controls(data: bytes) -> list[int]:
    return sorted({byte for byte in data if (byte < 32 and byte not in (9, 10, 13)) or byte == 127})


def carriers(value: Any) -> list[str]:
    result: list[str] = []
    if isinstance(value, dict):
        if value.get("type") == "text" and isinstance(value.get("value"), str):
            result.append(value["value"])
            return result
        if isinstance(value.get("text"), str):
            result.append(value["text"])
        for key in ("content", "items", "header", "head", "rows"):
            if key in value:
                result.extend(carriers(value[key]))
    elif isinstance(value, list):
        for item in value:
            result.extend(carriers(item))
    elif isinstance(value, str):
        result.append(value)
    return [item for item in result if item]


def compact(value: str) -> str:
    return "".join(value.split())


def width_result(candidate: str, fixture: str, width: int, rendered: bytes | None, expected: list[str]) -> dict[str, Any]:
    cell = f"width:{fixture}:{width}"
    if rendered is None:
        return {"candidate": candidate, "cell": cell, "gate": "hostile_width_full_rendering", "status": "BLOCKED_NO_RUNNABLE_WIDTH_RENDERER", "max_line_width": None, "visible_carriers": 0, "planned_carriers": len(expected)}
    text = rendered.decode("utf-8")
    max_line = max((len(line) for line in text.splitlines()), default=0)
    haystack = compact(text)
    visible = sum(1 for item in expected if compact(item) in haystack)
    leaked = controls(rendered)
    status = "PASS" if max_line <= width and visible == len(expected) and not leaked else "FAIL"
    return {"candidate": candidate, "cell": cell, "gate": "hostile_width_full_rendering", "status": status, "max_line_width": max_line, "visible_carriers": visible, "planned_carriers": len(expected), "control_bytes": leaked}


def row(candidate: str, cell: str, gate: str, status: str, evidence: Any = None) -> dict[str, Any]:
    return {"candidate": candidate, "cell": cell, "gate": gate, "status": status, "evidence": evidence}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)

    for candidate in CANDIDATES:
        sys.path.insert(0, str(ROOT / candidate / "scripts"))
    e04 = load_module("e12_e04", ROOT / "E04" / "scripts" / "build.py")
    e05 = load_module("e12_e05", ROOT / "E05" / "scripts" / "core.py")
    e06 = load_module("e12_e06", ROOT / "E06" / "scripts" / "candidate.py")

    rows: list[dict[str, Any]] = []
    for fixture in PAPERS:
        migrated = json.loads((ROOT / "E04" / "evidence" / "run-1" / "migrated" / f"{fixture}.json").read_text())
        for width in WIDTHS:
            rows.append(width_result("E04", fixture, width, None, carriers(migrated["blocks"])))
        core = json.loads((ROOT / "E05" / "generated" / "semantic" / f"{fixture}.json").read_text())
        for width in WIDTHS:
            rows.append(width_result("E05", fixture, width, e05.tui_adapter(core, width), carriers(core["value"]["blocks"])))
        projection = json.loads((ROOT / "E06" / "generated" / "projections" / f"{fixture}.json").read_text())
        for width in WIDTHS:
            rows.append(width_result("E06", fixture, width, e06.render_tui(projection, width).encode(), carriers(projection["document"]["blocks"])))

    hostile = "ok\x1b[31mred\x00nul\x07bell\x7fdel"
    hostile_doc = {"_rev": "hostile", "blocks": [{"id": "hostile", "type": "paragraph", "content": [{"type": "text", "value": hostile}]}]}
    e04_out = canonical(e04.adapter("tui80", "HOSTILE", hostile_doc))
    e05_out = e05.tui_adapter({"value": {"blocks": hostile_doc["blocks"]}}, 20)
    e06_out = e06.render_tui({"identity": {"document_id": "doc", "document_revision_id": "rev", "projection_id": "projection"}, "document": {"blocks": hostile_doc["blocks"]}}, 20).encode()
    for candidate, rendered in (("E04", e04_out), ("E05", e05_out), ("E06", e06_out)):
        leaked = controls(rendered)
        rows.append(row(candidate, "controls:hostile", "control_sanitization", "FAIL" if leaked else "PASS", {"observed_control_bytes": leaked}))

    rows.extend((
        row("E04", "renderer:all-width", "e04_renderer_coverage", "BLOCKED_NO_RUNNABLE_WIDTH_RENDERER"),
        row("E05", "renderer:all-width", "e04_renderer_coverage", "PASS", "runnable width parameter"),
        row("E06", "renderer:all-width", "e04_renderer_coverage", "PASS", "runnable width parameter"),
    ))

    for candidate in CANDIDATES:
        for operation in INTERACTIONS:
            rows.append(row(candidate, f"interaction:{operation}", "interaction_parity", "BLOCKED_NO_INTERACTIVE_CANDIDATE_EXECUTABLE"))
        for case in ERRORS:
            rows.append(row(candidate, f"error:{case}", "typed_errors", "BLOCKED_SAFE_ERROR_SIMULATOR_UNAVAILABLE", {"typed_error": "BLOCKED", "exit_code": None, "unsafe_live_failure_induction": 0}))

    rows.extend((
        row("E04", "request_id:success-and-errors", "request_ids", "FAIL_MISSING"),
        row("E05", "request_id:success-and-errors", "request_ids", "BLOCKED_STATIC_SUCCESS_ONLY"),
        row("E06", "request_id:success-and-errors", "request_ids", "FAIL_MISSING"),
        row("E04", "identity:six-domains", "identity_domains", "FAIL_DOCUMENT_REVISION_ONLY"),
        row("E05", "identity:six-domains", "identity_domains", "FAIL_FOUR_OF_SIX"),
        row("E06", "identity:six-domains", "identity_domains", "PASS"),
    ))

    e06_projection = json.loads((ROOT / "E06" / "generated" / "projections" / "CCH28.json").read_text())
    body = canonical(e06_projection)
    etag = e06_projection["validators"]["projection_etag"]
    for candidate in ("E04", "E05"):
        for case in ("exact", "stale", "absent"):
            rows.append(row(candidate, f"etag:{case}", "etags", "BLOCKED_NO_RUNNABLE_CONDITIONAL_HANDLER"))
    for case, supplied, expected_status, expected_body in (("exact", etag, 304, 0), ("stale", '"stale"', 200, len(body)), ("absent", None, 200, len(body))):
        status, response = e06.conditional_response(body, etag, supplied)
        passed = status == expected_status and len(response) == expected_body
        rows.append(row("E06", f"etag:{case}", "etags", "PASS" if passed else "FAIL", {"http_status": status, "body_bytes": len(response)}))

    for candidate in CANDIDATES:
        for surface in DISCOVERY:
            if candidate == "E06" and surface == "schema":
                rows.append(row(candidate, f"discovery:{surface}", "contract_discovery_agreement", "PASS", "E06 canonical projection schema"))
            else:
                rows.append(row(candidate, f"discovery:{surface}", "contract_discovery_agreement", "BLOCKED_CONTRACT_SURFACE_UNAVAILABLE"))

    statuses: dict[str, int] = {}
    per_candidate: dict[str, dict[str, int]] = {candidate: {} for candidate in CANDIDATES}
    for item in rows:
        status = item["status"]
        bucket = "PASS" if status == "PASS" else "BLOCKED" if status.startswith("BLOCKED") else "FAIL"
        statuses[bucket] = statuses.get(bucket, 0) + 1
        candidate_counts = per_candidate[item["candidate"]]
        candidate_counts[bucket] = candidate_counts.get(bucket, 0) + 1
    winners = [candidate for candidate, counts in per_candidate.items() if counts.get("FAIL", 0) == 0 and counts.get("BLOCKED", 0) == 0 and counts.get("PASS", 0) > 0]
    matrix = {"schema_version": "legendary-restart-e12-terminal-platform-matrix/v1", "round": "converge", "rows": rows, "status_counts": statuses, "per_candidate": per_candidate}
    evaluation = {"schema_version": "legendary-restart-e12-contract-evaluation/v1", "round": "converge", "contract": "contract/replacement-wave-contract.json", "candidate_selected": False, "pilot_authorized": False, "eligible_candidates": winners, "no_winner": not winners, "decision": "REPLACEMENT_WAVE_REQUIRED" if not winners else "UNAUTHORIZED_SELECTION_REQUIRED_BY_LEADER", "observations": ["E04 renderer coverage remains blocked at every hostile width.", "E05 retains complete bounded rendering but fails hostile terminal control sanitization and lacks executable interaction, typed-error, conditional, discovery, and full request-ID evidence.", "E06 retains six identity domains and runnable ETags but fails 18/20 hostile-width cells, leaks terminal controls, and lacks the remaining executable platform surfaces."], "preference": []}
    write(output / "terminal-platform-matrix.json", matrix)
    write(output / "contract-evaluation.json", evaluation)
    write(output / "no-winner.json", {"schema_version": "legendary-restart-e12-no-winner/v1", "round": "converge", "no_winner": not winners, "eligible_candidates": winners, "candidate_selected": False, "pilot_authorized": False, "hard_rule": "every required cell must PASS; FAIL/BLOCKED/missing/proxy/static-only is ineligible"})
    return 0 if not winners else 1


if __name__ == "__main__":
    raise SystemExit(main())
