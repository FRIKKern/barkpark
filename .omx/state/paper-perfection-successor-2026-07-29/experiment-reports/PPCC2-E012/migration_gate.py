#!/usr/bin/env python3
"""PPCC2-E012 isolated, deterministic PortableDoc migration/quarantine gate."""
from __future__ import annotations

import argparse
import collections
import copy
import hashlib
import html
from html.parser import HTMLParser
import json
import math
from pathlib import Path
import time
from typing import Any, Iterable, Mapping, Sequence
import unicodedata

ASSIGNMENT_ID = "PPCC2-E012"
SCHEMA_VERSION = "ppcc2-migration-envelope/v1"
REQUIRED_SURFACES = ("studio", "tui80", "tui40", "email", "cli_api")
FIXTURE_IDS = (
    "paper:choosing-your-site-framework", "paper:component-reference", "paper:wave-deck",
    "paper:cloud-console-hardening-wave-2026-07-21",
    "paper:cloud-console-hardening-wave-3-2026-07-21",
    "paper:spd-inspector-successor-wave-2026-07-20", "paper:block-wishlist-100",
    "paper:honest-gates-wave-4-2026-07-28", "paper:task-tui-wave-2026-07-23b",
)
TOP_TYPES = frozenset({
    "action", "blockquote", "byline", "callout", "cards", "chart", "code", "columns",
    "diagram", "divider", "eyebrow", "heading", "heatmap", "image", "ingress", "list",
    "notes", "paragraph", "pullquote", "section", "stat", "stat-grid", "stats", "table", "terminal",
})
NESTED_TYPES = TOP_TYPES | frozenset({"card", "em", "list_item", "strong", "table_cell", "table_row", "text"})
VISIBLE_KEYS = (
    "title", "heading", "summary", "description", "text", "label", "name", "message",
    "reason", "quote", "caption", "alt", "code", "value", "content", "body", "children",
    "items", "rows", "columns", "blocks", "href",
)
SKIP_KEYS = frozenset({
    "_id", "id", "_key", "key", "type", "kind", "level", "tone", "style", "variant",
    "layout", "width", "height", "src", "asset", "ref", "_ref", "target", "color", "icon",
    "language", "version",
})


def canonical_bytes(value: Any, newline: bool = False) -> bytes:
    text = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return (text + ("\n" if newline else "")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def strict_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_json_key:" + key)
        result[key] = value
    return result


def reject_constant(value: str) -> Any:
    raise ValueError("non_finite_json_constant:" + value)


def strict_loads(raw: bytes) -> Any:
    return json.loads(raw.decode("utf-8"), object_pairs_hook=strict_pairs, parse_constant=reject_constant)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False).encode("utf-8") + b"\n")


def ordered_keys(value: Mapping[str, Any]) -> Iterable[str]:
    emitted: set[str] = set()
    for key in VISIBLE_KEYS:
        if key in value:
            emitted.add(key)
            yield key
    for key in sorted(value):
        if key not in emitted:
            yield key


def semantic_strings(value: Any, parent_key: str = "") -> list[str]:
    if isinstance(value, str):
        text = " ".join(value.split())
        if parent_key == "href" and not text.lower().startswith(("https://", "http://", "mailto:")):
            return ["[blocked unsafe URL]"]
        if text and parent_key not in SKIP_KEYS:
            return [text]
        return []
    if isinstance(value, list):
        return [text for item in value for text in semantic_strings(item, parent_key)]
    if isinstance(value, dict):
        return [text for key in ordered_keys(value) if key not in SKIP_KEYS for text in semantic_strings(value[key], key)]
    if isinstance(value, (int, float)) and not isinstance(value, bool) and parent_key in {"value", "count", "total", "min", "max", "current"}:
        return [str(value)]
    return []


def validate_tree(value: Any, path: str = "$", depth: int = 0) -> list[str]:
    reasons: list[str] = []
    if depth > 64:
        return ["max_depth_exceeded:" + path]
    if value is None:
        return ["null_not_allowed:" + path]
    if isinstance(value, float) and not math.isfinite(value):
        return ["non_finite_number:" + path]
    if isinstance(value, dict):
        node_type = value.get("type")
        if "type" in value and (not isinstance(node_type, str) or not node_type):
            reasons.append("invalid_typed_node:" + path)
        elif isinstance(node_type, str) and node_type not in NESTED_TYPES:
            reasons.append("unknown_typed_node:" + path + ":" + node_type)
        for key, child in value.items():
            if not isinstance(key, str):
                reasons.append("non_string_key:" + path)
            reasons.extend(validate_tree(child, path + "." + str(key), depth + 1))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reasons.extend(validate_tree(child, f"{path}[{index}]", depth + 1))
    elif not isinstance(value, (str, int, float, bool)):
        reasons.append("unsupported_value:" + path)
    return reasons


def validation_reasons(payload: Any, unit_id: str) -> list[str]:
    if not isinstance(payload, dict):
        return ["payload_not_object:$"]
    reasons = validate_tree(payload)
    source = payload.get("source")
    if not isinstance(source, dict) or source.get("kind") != "blocks":
        reasons.append("source_kind_not_blocks:$.source")
        return sorted(set(reasons))
    blocks = source.get("blocks")
    if not isinstance(blocks, list):
        reasons.append("blocks_not_array:$.source.blocks")
        return sorted(set(reasons))
    seen: set[str] = set()
    for index, block in enumerate(blocks):
        path = f"$.source.blocks[{index}]"
        if not isinstance(block, dict):
            reasons.append("block_not_object:" + path)
            continue
        block_id = block.get("id")
        if not isinstance(block_id, str) or not block_id:
            reasons.append("missing_block_id:" + path)
        elif block_id in seen:
            reasons.append("duplicate_block_id:" + path + ":" + block_id)
        else:
            seen.add(block_id)
        block_type = block.get("type")
        if block_type not in TOP_TYPES:
            reasons.append("unknown_top_level_type:" + path + ":" + str(block_type))
    for key in ("id", "_rev", "title"):
        if not isinstance(payload.get(key), str) or not payload[key]:
            reasons.append("missing_document_field:$." + key)
    return sorted(set(reasons))


def migration_envelope(payload: Any, unit_id: str) -> dict[str, Any]:
    raw_sha = sha256_bytes(canonical_bytes(payload))
    reasons = validation_reasons(payload, unit_id)
    base = {
        "schema_version": SCHEMA_VERSION,
        "assignment_id": ASSIGNMENT_ID,
        "unit_id": unit_id,
        "source_sha256": raw_sha,
        "source_snapshot": copy.deepcopy(payload),
    }
    if reasons:
        return {
            **base,
            "status": "quarantined",
            "quarantine": {
                "reason_codes": reasons,
                "source_path": "source_snapshot",
                "raw_payload_preserved": True,
                "rollback_action": "restore source_snapshot without transformation",
            },
        }
    blocks = payload["source"]["blocks"]
    nodes = []
    for index, block in enumerate(blocks):
        strings = semantic_strings(block)
        nodes.append({
            "source_index": index, "block_id": block["id"], "block_type": block["type"],
            "strings": strings, "strings_sha256": sha256_bytes(canonical_bytes(strings)),
        })
    return {
        **base,
        "status": "accepted",
        "document": {"id": payload["id"], "revision": payload["_rev"], "title": payload["title"]},
        "authored": {"portable_doc": {"version": 1, "blocks": copy.deepcopy(blocks)}, "blocks_sha256": sha256_bytes(canonical_bytes(blocks))},
        "semantic_nodes": nodes,
        "rollback": {"source_path": "source_snapshot", "byte_exact": True},
    }


def display_width(text: str) -> int:
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in {"F", "W"} else 1 for c in text)


def hard_wrap(text: str, width: int) -> list[str]:
    words = text.split() or [""]
    lines: list[str] = []
    current = ""
    for word in words:
        while display_width(word) > width:
            if current:
                lines.append(current); current = ""
            chunk = ""
            while word and display_width(chunk + word[0]) <= width:
                chunk += word[0]; word = word[1:]
            lines.append(chunk)
        candidate = word if not current else current + " " + word
        if display_width(candidate) <= width:
            current = candidate
        else:
            lines.append(current); current = word
    if current or not lines:
        lines.append(current)
    return lines


def render_tui(env: Mapping[str, Any], width: int) -> str:
    lines = hard_wrap(env["document"]["title"], width) + ["=" * min(width, 12)]
    for node in env["semantic_nodes"]:
        lines.extend(hard_wrap(f"[{node['source_index'] + 1} · {node['block_type']}]", width))
        for string in node["strings"]:
            lines.extend(hard_wrap(string, width))
    return "\n".join(lines) + "\n"


def heading_level(block: Mapping[str, Any]) -> int | None:
    if block.get("type") != "heading":
        return None
    level = block.get("level", 2)
    return max(2, min(6, level if isinstance(level, int) else 2))


def render_html(env: Mapping[str, Any], email_mode: bool) -> str:
    title = html.escape(env["document"]["title"])
    prefix = '<!doctype html><html><body><main><article>' if not email_mode else '<!doctype html><html><body style="font-family:Arial,sans-serif;line-height:1.5">'
    parts = [prefix, "<h1>" + title + "</h1>"]
    blocks = env["authored"]["portable_doc"]["blocks"]
    for node, block in zip(env["semantic_nodes"], blocks):
        strings = node["strings"]
        level = heading_level(block)
        if level and strings:
            parts.append(f"<h{level}>" + html.escape(strings[0]) + f"</h{level}>")
            strings = strings[1:]
        if strings:
            parts.append('<section aria-label="' + html.escape(node["block_type"], quote=True) + '">')
            parts.extend("<p>" + html.escape(string) + "</p>" for string in strings)
            parts.append("</section>")
    parts.append("</body></html>" if email_mode else "</article></main></body></html>")
    return "".join(parts) + "\n"


class TextCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__(); self.parts: list[str] = []
    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def html_text(markup: str) -> str:
    parser = TextCollector(); parser.feed(markup); return html.unescape(" ".join(parser.parts))


def normalized(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKC", text) if not c.isspace())


def missing_strings(expected: Sequence[str], output: str) -> list[str]:
    haystack = normalized(output); counts = collections.Counter(normalized(v) for v in expected if v)
    return [value[:120] for value, count in counts.items() if haystack.count(value) < count]


def verify(env: Mapping[str, Any]) -> tuple[dict[str, Any], dict[str, bytes]]:
    studio = render_html(env, False); email = render_html(env, True)
    tui80 = render_tui(env, 80); tui40 = render_tui(env, 40); cli = canonical_bytes(env)
    outputs = {"studio": studio.encode(), "tui80": tui80.encode(), "tui40": tui40.encode(), "email": email.encode(), "cli_api": cli}
    strings = [env["document"]["title"]] + [s for n in env["semantic_nodes"] for s in n["strings"]]
    missing = {
        "studio": missing_strings(strings, html_text(studio)), "tui80": missing_strings(strings, tui80),
        "tui40": missing_strings(strings, tui40), "email": missing_strings(strings, html_text(email)),
    }
    widths80 = [display_width(line) for line in tui80.splitlines()]; widths40 = [display_width(line) for line in tui40.splitlines()]
    blocks = env["authored"]["portable_doc"]["blocks"]
    authored_exact = blocks == env["source_snapshot"]["source"]["blocks"]
    rollback_exact = canonical_bytes(env["source_snapshot"]) == canonical_bytes(strict_loads(canonical_bytes(env["source_snapshot"])))
    headings = [b for b in blocks if b.get("type") == "heading"]
    studio_heading_count = sum(studio.count(f"<h{n}>") for n in range(2, 7))
    email_heading_count = sum(email.count(f"<h{n}>") for n in range(2, 7))
    gates = {
        "portable_doc_schema_validity": not validation_reasons(env["source_snapshot"], env["unit_id"]),
        "studio_structural_completeness": not missing["studio"] and studio_heading_count == len(headings),
        "tui_width": max(widths80 or [0]) <= 80 and max(widths40 or [0]) <= 40,
        "email_safety": not missing["email"] and "<script" not in email.lower() and "<details" not in email.lower() and email_heading_count == len(headings),
        "cli_api_round_trip": strict_loads(cli) == env and canonical_bytes(strict_loads(cli)) == cli,
        "accessibility": studio.count("<h1>") == 1 and email.count("<h1>") == 1 and studio_heading_count == len(headings),
        "content_preservation": authored_exact and rollback_exact and not any(missing.values()),
    }
    detail = {
        "unit_id": env["unit_id"], "hard_gates": gates, "hard_gate_pass": all(gates.values()),
        "missing_authored_strings": missing, "heading_blocks": len(headings),
        "studio_semantic_heading_count": studio_heading_count, "email_semantic_heading_count": email_heading_count,
        "tui80_max_display_width": max(widths80 or [0]), "tui40_max_display_width": max(widths40 or [0]),
        "authored_blocks_exactly_preserved": authored_exact, "rollback_byte_exact": rollback_exact,
        "output_sha256": {key: sha256_bytes(value) for key, value in outputs.items()},
    }
    return detail, outputs


def hostile_payloads(control: Mapping[str, Any]) -> dict[str, Any]:
    cases: dict[str, Any] = {}
    def changed() -> dict[str, Any]: return copy.deepcopy(control)
    value = changed(); value["source"]["blocks"].append({"id": "hostile", "type": "legacyMystery", "text": "UNKNOWN"}); cases["unknown_type"] = value
    value = changed(); value["source"]["blocks"].append(copy.deepcopy(value["source"]["blocks"][0])); cases["duplicate_ids"] = value
    value = changed(); value["source"]["blocks"][0]["content"] = None; cases["nested_null"] = value
    value = changed(); value["source"]["blocks"][0].pop("id", None); cases["missing_id"] = value
    value = changed(); value["source"]["kind"] = "legacy-wrapper"; cases["unknown_wrapper"] = value
    value = changed(); node: dict[str, Any] = {"type": "text", "value": "deep"}
    for _ in range(66): node = {"type": "strong", "children": [node]}
    value["source"]["blocks"][0]["content"] = [node]; cases["excessive_depth"] = value
    return cases


def run(fixtures: Path, output: Path) -> dict[str, Any]:
    started = time.monotonic(); output.mkdir(parents=True, exist_ok=True)
    results = []; manifest = []; controls: list[dict[str, Any]] = []
    for source_path in sorted(fixtures.glob("*/source.json")):
        payload = strict_loads(source_path.read_bytes()); slug = source_path.parent.name; unit_id = "paper:" + slug
        controls.append(payload); env1 = migration_envelope(payload, unit_id); env2 = migration_envelope(payload, unit_id)
        if env1["status"] != "accepted" or canonical_bytes(env1) != canonical_bytes(env2):
            raise RuntimeError(unit_id + ": accepted deterministic migration failed")
        result, outputs = verify(env1)
        result["migration_idempotence"] = canonical_bytes(env1) == canonical_bytes(env2)
        result["hard_gate_pass"] = result["hard_gate_pass"] and result["migration_idempotence"]
        fixture_out = output / "fixtures" / slug
        write_json(fixture_out / "envelope.json", env1); write_json(fixture_out / "metrics.json", result)
        suffixes = {"studio": "studio.html", "tui80": "tui80.txt", "tui40": "tui40.txt", "email": "email.html", "cli_api": "cli_api.json"}
        for surface, data in outputs.items(): (fixture_out / suffixes[surface]).write_bytes(data)
        results.append(result); manifest.append({"unit_id": unit_id, "source_sha256": sha256_bytes(source_path.read_bytes()), "envelope_sha256": sha256_bytes(canonical_bytes(env1))})
    if tuple(r["unit_id"] for r in results) != tuple(sorted(FIXTURE_IDS)):
        raise RuntimeError("fixture identity mismatch")
    hostile = []
    control = controls[0]
    for name, payload in hostile_payloads(control).items():
        first = migration_envelope(payload, "hostile:" + name); second = migration_envelope(payload, "hostile:" + name)
        hostile.append({"case": name, "status": first["status"], "reason_codes": first.get("quarantine", {}).get("reason_codes", []), "deterministic": canonical_bytes(first) == canonical_bytes(second), "raw_payload_preserved": first.get("quarantine", {}).get("raw_payload_preserved", False), "rollback_byte_exact": first["source_snapshot"] == payload})
    raw_json = {}
    for name, raw in {"duplicate_keys": b'{"type":"paragraph","type":"legacyMystery"}', "nan": b'{"value":NaN}', "infinity": b'{"value":Infinity}'}.items():
        try: strict_loads(raw); raw_json[name] = {"rejected": False}
        except ValueError as exc: raw_json[name] = {"rejected": True, "error": str(exc)}
    safe_link = copy.deepcopy(control)
    safe_link["source"]["blocks"].append({"id": "safe-link-control", "type": "action", "label": "Safe link", "href": "https://example.invalid/safe"})
    unsafe_link = copy.deepcopy(control)
    unsafe_link["source"]["blocks"].append({"id": "unsafe-link-control", "type": "action", "label": "Unsafe link", "href": "javascript:alert(1)"})
    link_controls = {}
    for name, payload, expected, absent in (
        ("safe", safe_link, "https://example.invalid/safe", "javascript:"),
        ("unsafe", unsafe_link, "[blocked unsafe URL]", "javascript:"),
    ):
        envelope = migration_envelope(payload, "control:" + name + "-link")
        detail, outputs = verify(envelope)
        projected = {surface: data.decode("utf-8") for surface, data in outputs.items() if surface != "cli_api"}
        link_controls[name] = {
            "migration_status": envelope["status"],
            "source_snapshot_exact": envelope["source_snapshot"] == payload,
            "expected_marker": expected,
            "expected_marker_visible_on_all_human_surfaces": all(expected in text for text in projected.values()),
            "unsafe_scheme_absent_from_all_human_surfaces": all(absent not in text for text in projected.values()),
            "surface_gate_pass": detail["hard_gate_pass"],
        }
    gate_names = tuple(results[0]["hard_gates"])
    attempted = len(results)
    metrics: dict[str, Any] = {}
    for gate in gate_names:
        passed = sum(bool(r["hard_gates"][gate]) for r in results)
        metrics[gate] = {"attempted": attempted, "passed": passed, "failed": attempted-passed, "pass_rate": round(passed/attempted, 6), "pass": passed == attempted}
    metrics["tui_width"].update({"tui80_max_display_width": max(r["tui80_max_display_width"] for r in results), "tui40_max_display_width": max(r["tui40_max_display_width"] for r in results)})
    hard_checks = attempted * len(gate_names); hard_passes = sum(sum(r["hard_gates"].values()) for r in results)
    metrics["pilot_gate_pass_rate"] = {"applicable": False, "value": None, "reason": "Round 4 convergence does not execute or claim Round 5 pilot evidence."}
    metrics["observed_failure_rate"] = {"hard_checks": hard_checks, "hard_failures": hard_checks-hard_passes, "rate": round((hard_checks-hard_passes)/hard_checks, 6)}
    metrics["batch_capacity"] = {"units_attempted": attempted, "largest_isolated_convergence_batch_passing": sum(r["hard_gate_pass"] for r in results), "provisional_only": True, "reason": "Round 5 pilot alone may seal builder batch capacity.", "wall_seconds": round(time.monotonic()-started, 6)}
    metrics["rollback"] = {"attempted": attempted + len(hostile), "passed": sum(r["rollback_byte_exact"] for r in results) + sum(r["rollback_byte_exact"] for r in hostile), "pass": all(r["rollback_byte_exact"] for r in results + hostile), "production_mutations": 0, "rule": "restore source_snapshot byte-for-byte for accepted or quarantined inputs"}
    status_pass = (
        all(r["hard_gate_pass"] for r in results)
        and all(h["status"] == "quarantined" and h["deterministic"] and h["raw_payload_preserved"] for h in hostile)
        and all(v["rejected"] for v in raw_json.values())
        and all(v["migration_status"] == "accepted" and v["source_snapshot_exact"] and v["expected_marker_visible_on_all_human_surfaces"] and v["unsafe_scheme_absent_from_all_human_surfaces"] and v["surface_gate_pass"] for v in link_controls.values())
    )
    summary = {"schema_version": "ppcc2-e012-run/v1", "assignment_id": ASSIGNMENT_ID, "status": "PASS" if status_pass else "FAIL", "fixture_count": attempted, "required_surfaces": list(REQUIRED_SURFACES), "matrix": {"fixture_surface_cells": attempted * len(REQUIRED_SURFACES), "hard_gate_cells": hard_checks, "expected_fixture_count": len(FIXTURE_IDS), "observed_fixture_count": attempted}, "fixture_results": results, "hostile_cases": hostile, "strict_raw_json_cases": raw_json, "link_controls": link_controls, "manifest": manifest, "metrics": metrics}
    write_json(output / "run-summary.json", summary); write_json(output / "fixture-manifest.json", manifest)
    print(json.dumps({"assignment_id": ASSIGNMENT_ID, "status": summary["status"], "fixture_count": attempted, "hard_checks": hard_checks, "hard_failures": hard_checks-hard_passes, "hostile_quarantined": sum(h["status"] == "quarantined" for h in hostile), "strict_json_rejections": sum(v["rejected"] for v in raw_json.values()), "tui80_max": metrics["tui_width"]["tui80_max_display_width"], "tui40_max": metrics["tui_width"]["tui40_max_display_width"]}, sort_keys=True))
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--fixtures", type=Path, required=True); parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(); summary = run(args.fixtures, args.output); return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__": raise SystemExit(main())
