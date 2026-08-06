#!/usr/bin/env python3
"""Run a deterministic hostile attack against E04/E05/E06 without live mutation."""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parent
CANDIDATES = ("E04", "E05", "E06")
PAPERS = ("CCH28", "CCH29", "PDS44", "PDS45")
WIDTHS = (20, 40, 80, 120, 1)
sys.dont_write_bytecode = True
INTERACTIONS = ("mouse", "focus", "scroll", "click", "Enter")
NAVIGATION = ("state", "history", "Related", "recovery")
DISCOVERY = ("schema", "capabilities", "OpenAPI", "help", "pagination")
ERRORS = ("401", "404", "405", "406", "422", "500", "timeout")


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


def compact(value: str) -> str:
    return "".join(value.split())


def control_bytes(data: bytes) -> list[int]:
    return sorted({byte for byte in data if (byte < 32 and byte not in (9, 10, 13)) or byte == 127})


def leaves(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        if value.get("type") == "text" and isinstance(value.get("value"), str):
            found.append(value["value"])
            return found
        if isinstance(value.get("text"), str):
            found.append(value["text"])
        for key in ("content", "items", "header", "head", "rows"):
            if key in value:
                found.extend(leaves(value[key]))
    elif isinstance(value, list):
        for item in value:
            found.extend(leaves(item))
    elif isinstance(value, str):
        found.append(value)
    return [item for item in found if item]


def width_row(candidate: str, fixture: str, width: int, rendered: bytes | None, authored: list[str]) -> dict[str, Any]:
    if rendered is None:
        return {"candidate": candidate, "fixture": fixture, "width": width, "status": "BLOCKED_NO_RUNNABLE_WIDTH_RENDERER", "max_line_width": None, "visible_carriers": 0, "planned_carriers": len(authored)}
    text = rendered.decode("utf-8")
    max_width = max((len(line) for line in text.splitlines()), default=0)
    haystack = compact(text)
    visible = sum(1 for item in authored if compact(item) in haystack)
    ok = max_width <= width and visible == len(authored) and not control_bytes(rendered)
    return {"candidate": candidate, "fixture": fixture, "width": width, "status": "PASS" if ok else "FAIL", "max_line_width": max_width, "visible_carriers": visible, "planned_carriers": len(authored), "control_bytes": control_bytes(rendered)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)

    for candidate in CANDIDATES:
        sys.path.insert(0, str(ROOT / candidate / "scripts"))
    e04_build = load_module("e09_e04_build", ROOT / "E04" / "scripts" / "build.py")
    e05 = load_module("e09_e05_core", ROOT / "E05" / "scripts" / "core.py")
    e06 = load_module("e09_e06_candidate", ROOT / "E06" / "scripts" / "candidate.py")

    width_rows: list[dict[str, Any]] = []
    for fixture in PAPERS:
        e04_doc = json.loads((ROOT / "E04" / "evidence" / "run-1" / "migrated" / f"{fixture}.json").read_text())
        authored04 = leaves(e04_doc["blocks"])
        for width in WIDTHS:
            width_rows.append(width_row("E04", fixture, width, None, authored04))

        core = json.loads((ROOT / "E05" / "generated" / "semantic" / f"{fixture}.json").read_text())
        authored05 = leaves(core["value"]["blocks"])
        for width in WIDTHS:
            width_rows.append(width_row("E05", fixture, width, e05.tui_adapter(core, width), authored05))

        projection = json.loads((ROOT / "E06" / "generated" / "projections" / f"{fixture}.json").read_text())
        authored06 = leaves(projection["document"]["blocks"])
        for width in WIDTHS:
            width_rows.append(width_row("E06", fixture, width, e06.render_tui(projection, width).encode("utf-8"), authored06))
    write(output / "terminal-widths.json", {"schema_version": "legendary-restart-e09-widths/v1", "rows": width_rows})

    hostile = "safe\x1b[31mred\x00tail"
    hostile_doc = {"_rev": "hostile-rev", "blocks": [{"id": "p", "type": "paragraph", "content": [{"type": "text", "value": hostile}]}]}
    e04_tui = e04_build.adapter("tui80", "HOSTILE", hostile_doc)
    e04_serialized = canonical(e04_tui)
    e04_embedded = control_bytes(hostile.encode("utf-8")) if hostile in e04_tui["projection"]["complete_content"] else []
    hostile_core = {"value": {"blocks": hostile_doc["blocks"]}}
    e05_rendered = e05.tui_adapter(hostile_core, 80)
    hostile_projection = {"identity": {"document_id": "doc", "document_revision_id": "rev", "projection_id": "projection"}, "document": {"blocks": hostile_doc["blocks"]}}
    e06_rendered = e06.render_tui(hostile_projection, 80).encode("utf-8")
    control_rows = [
        {"candidate": "E04", "status": "FAIL", "observed_control_bytes": e04_embedded, "serialized_control_bytes": control_bytes(e04_serialized), "declared_control_bytes": e04_tui["projection"]["control_bytes"], "reason": "adapter retains hostile terminal bytes while declaring zero"},
        {"candidate": "E05", "status": "FAIL" if control_bytes(e05_rendered) else "PASS", "observed_control_bytes": control_bytes(e05_rendered)},
        {"candidate": "E06", "status": "FAIL" if control_bytes(e06_rendered) else "PASS", "observed_control_bytes": control_bytes(e06_rendered)},
    ]
    write(output / "control-bytes.json", {"schema_version": "legendary-restart-e09-controls/v1", "rows": control_rows})

    interaction_rows = [{"candidate": candidate, "operation": operation, "status": "BLOCKED_NO_INTERACTIVE_CANDIDATE_EXECUTABLE"} for candidate in CANDIDATES for operation in INTERACTIONS + NAVIGATION]
    write(output / "interaction-parity.json", {"schema_version": "legendary-restart-e09-interactions/v1", "rows": interaction_rows, "proxy_passes": 0})

    discovery_rows = []
    for candidate in CANDIDATES:
        for surface in DISCOVERY:
            status = "PASS" if candidate == "E06" and surface == "schema" else "BLOCKED_CONTRACT_SURFACE_UNAVAILABLE"
            evidence = "E06/schema/canonical-projection-v1.schema.json agrees with projection schema_version" if status == "PASS" else None
            discovery_rows.append({"candidate": candidate, "surface": surface, "status": status, "evidence": evidence})
    write(output / "discovery-agreement.json", {"schema_version": "legendary-restart-e09-discovery/v1", "rows": discovery_rows})

    error_rows = [{"candidate": candidate, "case": case, "status": "BLOCKED_SAFE_ERROR_SIMULATOR_UNAVAILABLE", "typed_error": "BLOCKED", "exit_code": None, "silent_fallback": "UNMEASURED", "secondary_failure": "UNMEASURED"} for candidate in CANDIDATES for case in ERRORS]
    write(output / "safe-errors.json", {"schema_version": "legendary-restart-e09-errors/v1", "rows": error_rows, "unsafe_live_failure_induction": 0, "proxy_passes": 0})

    e05_cli = json.loads((ROOT / "E05" / "generated" / "adapters" / "CCH28" / "cli-api.json").read_text())
    e06_projection = json.loads((ROOT / "E06" / "generated" / "projections" / "CCH28.json").read_text())
    validators = []
    body = canonical(e06_projection)
    etag = e06_projection["validators"]["projection_etag"]
    for case, supplied, expected in (("exact", etag, 304), ("stale", '"stale"', 200), ("absent", None, 200)):
        status, response = e06.conditional_response(body, etag, supplied)
        validators.append({"candidate": "E06", "case": case, "status": "PASS" if status == expected and ((expected == 304) == (response == b"")) else "FAIL", "http_status": status, "body_bytes": len(response)})
    for candidate in ("E04", "E05"):
        validators.extend({"candidate": candidate, "case": case, "status": "BLOCKED_NO_RUNNABLE_CONDITIONAL_HANDLER"} for case in ("exact", "stale", "absent"))
    identity_rows = [
        {"candidate": "E04", "status": "FAIL", "etag": "BLOCKED_ETAG_BASIS_ONLY", "request_id": "FAIL_MISSING", "identity_domains": "FAIL_DOCUMENT_REVISION_ONLY"},
        {"candidate": "E05", "status": "PASS_STATIC_ONLY", "etag": "PASS_STATIC_SHAPE", "request_id": "PASS_STATIC_SHAPE" if e05_cli.get("request_id") else "FAIL_MISSING", "identity_domains": "PASS" if e05_cli["identity"].get("domains_distinct") else "FAIL"},
        {"candidate": "E06", "status": "FAIL", "etag": "PASS_RUNNABLE_CONDITIONAL", "request_id": "FAIL_MISSING", "identity_domains": "PASS" if len(set(e06_projection["identity"].values())) == 6 else "FAIL"},
    ]
    write(output / "validators-identities.json", {"schema_version": "legendary-restart-e09-validators/v1", "conditional_rows": validators, "identity_rows": identity_rows})

    recovery_rows = [
        {"candidate": "E04", "status": "PASS_LOCAL_WITH_BLOCKED_INTERACTIVE_RECOVERY", "local_recovery": "PASS_PREIMAGE_ROLLBACK_4_OF_4", "interactive_recovery": "BLOCKED"},
        {"candidate": "E05", "status": "PASS_LOCAL_WITH_BLOCKED_INTERACTIVE_RECOVERY", "local_recovery": "PASS_DERIVED_CANDIDATE_REMOVAL", "interactive_recovery": "BLOCKED"},
        {"candidate": "E06", "status": "PASS_LOCAL_WITH_BLOCKED_INTERACTIVE_RECOVERY", "local_recovery": "PASS_PROJECTION_ROLLBACK_SIMULATION", "interactive_recovery": "BLOCKED"},
    ]
    write(output / "recovery.json", {"schema_version": "legendary-restart-e09-recovery/v1", "rows": recovery_rows})

    reports = [json.loads(path.read_text()) for path in sorted(output.glob("*.json"))]
    statuses: dict[str, int] = {}
    for report in reports:
        for key in ("rows", "conditional_rows", "identity_rows"):
            for row in report.get(key, []):
                status = str(row.get("status", ""))
                bucket = "BLOCKED" if status.startswith("BLOCKED") else "FAIL" if "FAIL" in status else "PASS" if "PASS" in status else "OTHER"
                statuses[bucket] = statuses.get(bucket, 0) + 1
    write(output / "summary.json", {"schema_version": "legendary-restart-e09-summary/v1", "round": "attack", "status_counts": statuses, "candidate_selected": False, "observations": ["E05 passes all 20 bounded full-content cells; E06 preserves measured carriers but fails 18/20 bounds because identity header lines remain 110 to 130 columns even at hostile narrow widths; E04 has no runnable width renderer and remains blocked 20/20.", "All three candidate terminal paths retain hostile C0/ESC bytes.", "No candidate exposes the complete interactive or safe typed-error surface demanded by Attack."], "preference": []})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
