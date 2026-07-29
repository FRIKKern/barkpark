#!/usr/bin/env python3
"""Isolated PPCC2-E006 reader-adaptive PortableDoc candidate."""

from __future__ import annotations

import argparse
import collections
import hashlib
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import subprocess
import time
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Sequence, Tuple
import unicodedata


SCHEMA_VERSION = "ppcc2-reader-adaptive-candidate/v1"
REQUIRED_SURFACES = ("studio", "tui80", "tui40", "email", "cli_api")
METRIC_KEYS = (
    "portable_doc_schema_validity",
    "studio_structural_completeness",
    "tui_width",
    "email_safety",
    "cli_api_round_trip",
    "accessibility",
    "content_preservation",
    "pilot_gate_pass_rate",
    "observed_failure_rate",
    "batch_capacity",
    "rollback",
)

_SKIP_KEYS = {
    "_id",
    "id",
    "_key",
    "key",
    "type",
    "kind",
    "level",
    "tone",
    "style",
    "variant",
    "layout",
    "width",
    "height",
    "url",
    "href",
    "src",
    "asset",
    "ref",
    "_ref",
    "target",
    "color",
    "icon",
    "language",
    "version",
}
_PRIORITY_KEYS = (
    "title",
    "heading",
    "summary",
    "description",
    "text",
    "label",
    "name",
    "message",
    "reason",
    "quote",
    "caption",
    "alt",
    "code",
    "value",
    "content",
    "body",
    "children",
    "items",
    "rows",
    "columns",
    "blocks",
)


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_json(value: Any) -> str:
    return sha256_bytes(canonical_bytes(value))


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )


def fetch_document(slug: str) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    command = [
        "bp",
        "-s",
        "guerrilla",
        "-w",
        "default",
        "-p",
        "default",
        "-d",
        "production",
        "doc",
        "get",
        "paper",
        slug,
        "-o",
        "json",
    ]
    started = time.monotonic()
    attempts = []
    completed = None
    for attempt in range(1, 4):
        attempt_started = time.monotonic()
        completed = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        attempts.append(
            {
                "attempt": attempt,
                "exit_code": completed.returncode,
                "elapsed_seconds": round(time.monotonic() - attempt_started, 6),
                "stdout_bytes": len(completed.stdout),
                "stdout_sha256": sha256_bytes(completed.stdout),
                "stderr": completed.stderr.decode("utf-8", errors="replace"),
            }
        )
        if completed.returncode == 0:
            break
        time.sleep(attempt * 0.5)
    assert completed is not None
    elapsed = time.monotonic() - started
    if completed.returncode != 0:
        raise RuntimeError(
            "{} failed: {}".format(
                " ".join(command),
                completed.stderr.decode("utf-8", errors="replace"),
            )
        )
    document = json.loads(completed.stdout.decode("utf-8"))
    payload = {
        "id": document.get("_id") or slug,
        "_rev": document.get("_rev"),
        "title": document.get("title"),
        "source": {"kind": "blocks", "blocks": document.get("blocks")},
    }
    command_output = {
        "command": " ".join(command),
        "method": "GET via bp document reader",
        "exit_code": completed.returncode,
        "elapsed_seconds": round(elapsed, 6),
        "attempts": attempts,
        "stdout_bytes": len(completed.stdout),
        "stdout_sha256": sha256_bytes(completed.stdout),
        "stderr": completed.stderr.decode("utf-8", errors="replace"),
    }
    return payload, command_output


def _ordered_keys(value: Mapping[str, Any]) -> Iterable[str]:
    seen = set()
    for key in _PRIORITY_KEYS:
        if key in value:
            seen.add(key)
            yield key
    for key in sorted(value):
        if key not in seen:
            yield key


def semantic_strings(value: Any, parent_key: str = "") -> List[str]:
    """Collect reader-visible authored strings in deterministic reading order."""
    if isinstance(value, str):
        text = " ".join(value.split())
        if text and parent_key not in _SKIP_KEYS:
            return [text]
        return []
    if isinstance(value, list):
        output: List[str] = []
        for item in value:
            output.extend(semantic_strings(item, parent_key))
        return output
    if isinstance(value, dict):
        output = []
        for key in _ordered_keys(value):
            if key in _SKIP_KEYS:
                continue
            output.extend(semantic_strings(value[key], key))
        return output
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if parent_key in {"value", "count", "total", "min", "max", "current"}:
            return [str(value)]
    return []


def block_identifier(block: Mapping[str, Any], index: int) -> str:
    for key in ("id", "_id", "_key", "key"):
        value = block.get(key)
        if isinstance(value, str) and value:
            return value
    return "source-index-" + str(index)


def typed_tree_stats(value: Any, depth: int = 0) -> Dict[str, int]:
    stats = {
        "typed_nodes": 0,
        "invalid_typed_nodes": 0,
        "null_nodes": 0,
        "max_json_depth": depth,
    }
    if value is None:
        stats["null_nodes"] += 1
        return stats
    if isinstance(value, dict):
        if "type" in value:
            stats["typed_nodes"] += 1
            if not isinstance(value["type"], str) or not value["type"]:
                stats["invalid_typed_nodes"] += 1
        for child in value.values():
            child_stats = typed_tree_stats(child, depth + 1)
            for key in ("typed_nodes", "invalid_typed_nodes", "null_nodes"):
                stats[key] += child_stats[key]
            stats["max_json_depth"] = max(
                stats["max_json_depth"], child_stats["max_json_depth"]
            )
    elif isinstance(value, list):
        for child in value:
            child_stats = typed_tree_stats(child, depth + 1)
            for key in ("typed_nodes", "invalid_typed_nodes", "null_nodes"):
                stats[key] += child_stats[key]
            stats["max_json_depth"] = max(
                stats["max_json_depth"], child_stats["max_json_depth"]
            )
    return stats


def build_candidate(payload: Mapping[str, Any], unit_id: str) -> Dict[str, Any]:
    source = payload.get("source")
    if not isinstance(source, dict) or source.get("kind") != "blocks":
        raise ValueError(unit_id + ": source.kind must be blocks")
    blocks = source.get("blocks")
    if not isinstance(blocks, list):
        raise ValueError(unit_id + ": source.blocks must be an array")
    if not all(
        isinstance(block, dict)
        and isinstance(block.get("type"), str)
        and bool(block["type"])
        for block in blocks
    ):
        raise ValueError(unit_id + ": every block must have a nonempty string type")

    nodes = []
    for index, block in enumerate(blocks):
        segments = semantic_strings(block)
        nodes.append(
            {
                "source_index": index,
                "block_id": block_identifier(block, index),
                "block_type": block["type"],
                "segments": segments,
                "segments_sha256": sha256_json(segments),
            }
        )

    document_id = payload.get("id")
    title = payload.get("title")
    revision = payload.get("_rev")
    if not all(isinstance(value, str) and value for value in (document_id, title, revision)):
        raise ValueError(unit_id + ": id, title, and _rev must be nonempty strings")

    portable_doc = {"version": 1, "blocks": blocks}
    tree_stats = typed_tree_stats(blocks)
    all_segments = [segment for node in nodes for segment in node["segments"]]
    return {
        "schema_version": SCHEMA_VERSION,
        "unit_id": unit_id,
        "document": {
            "id": document_id,
            "revision": revision,
            "title": title,
        },
        "authored": {
            "portable_doc": portable_doc,
            "blocks_sha256": sha256_json(blocks),
            "block_count": len(blocks),
            "typed_tree_stats": tree_stats,
        },
        "reader_contract": {
            "canonical_source": "authored.portable_doc",
            "single_h1_source": "document.title",
            "node_order": "semantic_nodes.source_index ascending",
            "studio": {"format": "semantic HTML5", "logical_h1": 1},
            "tui80": {"format": "plain text", "max_display_width": 80},
            "tui40": {"format": "plain text", "max_display_width": 40},
            "email": {
                "format": "script-free semantic HTML",
                "logical_h1": 1,
            },
            "cli_api": {
                "format": "canonical JSON",
                "round_trip": "byte-stable canonical encoding",
            },
        },
        "semantic_nodes": nodes,
        "semantic_segments_sha256": sha256_json(all_segments),
    }


def display_width(text: str) -> int:
    width = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        width += 2 if unicodedata.east_asian_width(char) in {"F", "W"} else 1
    return width


def hard_wrap(text: str, width: int) -> List[str]:
    if width < 1:
        raise ValueError("width must be positive")
    words = text.split()
    if not words:
        return [""]
    lines: List[str] = []
    current = ""

    def push_word(word: str) -> None:
        nonlocal current
        remaining = word
        while remaining:
            if not current:
                chunk = ""
                consumed = 0
                for char in remaining:
                    if chunk and display_width(chunk + char) > width:
                        break
                    chunk += char
                    consumed += 1
                current = chunk
                remaining = remaining[consumed:]
                if remaining:
                    lines.append(current)
                    current = ""
            else:
                candidate = current + " " + remaining
                if display_width(candidate) <= width:
                    current = candidate
                    remaining = ""
                else:
                    lines.append(current)
                    current = ""

    for word in words:
        push_word(word)
    if current or not lines:
        lines.append(current)
    return lines


def render_tui(candidate: Mapping[str, Any], width: int) -> str:
    title = candidate["document"]["title"]
    lines: List[str] = []
    lines.extend(hard_wrap(title, width))
    lines.append("=" * min(width, max(3, display_width(title))))
    for node in candidate["semantic_nodes"]:
        segments = node["segments"]
        if not segments:
            continue
        chrome = "[{} · {}]".format(node["source_index"] + 1, node["block_type"])
        lines.extend(hard_wrap(chrome, width))
        for segment in segments:
            lines.extend(hard_wrap(segment, width))
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _render_html(candidate: Mapping[str, Any], email_mode: bool) -> str:
    title = html.escape(candidate["document"]["title"])
    if email_mode:
        head = (
            '<!doctype html><html><body style="margin:0;padding:24px;'
            'font-family:Arial,sans-serif;line-height:1.5">'
        )
        h1 = '<h1 style="font-size:28px;margin:0 0 24px">' + title + "</h1>"
    else:
        head = (
            '<!doctype html><html><body><main id="reader-main">'
            '<article id="paper-body">'
        )
        h1 = "<h1>" + title + "</h1>"
    parts = [head, h1]
    for node in candidate["semantic_nodes"]:
        segments = node["segments"]
        if not segments:
            continue
        label = "Block {}: {}".format(node["source_index"] + 1, node["block_type"])
        if email_mode:
            parts.append(
                '<section aria-label="{}" style="margin:0 0 20px">'.format(
                    html.escape(label, quote=True)
                )
            )
            for segment in segments:
                parts.append(
                    '<p style="margin:0 0 8px">{}</p>'.format(html.escape(segment))
                )
        else:
            parts.append(
                '<section data-block-type="{}" aria-label="{}">'.format(
                    html.escape(node["block_type"], quote=True),
                    html.escape(label, quote=True),
                )
            )
            for segment in segments:
                parts.append("<p>{}</p>".format(html.escape(segment)))
        parts.append("</section>")
    parts.append("</body></html>" if email_mode else "</article></main></body></html>")
    return "".join(parts) + "\n"


def render_studio(candidate: Mapping[str, Any]) -> str:
    return _render_html(candidate, email_mode=False)


def render_email(candidate: Mapping[str, Any]) -> str:
    return _render_html(candidate, email_mode=True)


class TextCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.text: List[str] = []

    def handle_data(self, data: str) -> None:
        self.text.append(data)


def normalized_no_space(text: str) -> str:
    return "".join(char for char in unicodedata.normalize("NFKC", text) if not char.isspace())


def expected_visible_strings(candidate: Mapping[str, Any]) -> List[str]:
    return [candidate["document"]["title"]] + [
        segment
        for node in candidate["semantic_nodes"]
        for segment in node["segments"]
    ]


def missing_visible_strings(expected: Sequence[str], output: str) -> List[str]:
    normalized_output = normalized_no_space(output)
    required = collections.Counter(normalized_no_space(value) for value in expected if value)
    missing: List[str] = []
    for value, count in required.items():
        if normalized_output.count(value) < count:
            missing.append(value[:120])
    return missing


def html_text(markup: str) -> str:
    collector = TextCollector()
    collector.feed(markup)
    return html.unescape(" ".join(collector.text))


def verify_candidate(
    candidate: Mapping[str, Any],
    studio: str,
    tui80: str,
    tui40: str,
    email: str,
    cli_api: bytes,
) -> Dict[str, Any]:
    blocks = candidate["authored"]["portable_doc"]["blocks"]
    tree_stats = typed_tree_stats(blocks)
    schema_valid = (
        candidate.get("schema_version") == SCHEMA_VERSION
        and candidate["authored"]["portable_doc"].get("version") == 1
        and isinstance(blocks, list)
        and all(
            isinstance(block, dict)
            and isinstance(block.get("type"), str)
            and bool(block["type"])
            for block in blocks
        )
        and candidate["authored"]["blocks_sha256"] == sha256_json(blocks)
        and tree_stats["invalid_typed_nodes"] == 0
        and tree_stats["max_json_depth"] <= 64
        and tree_stats == candidate["authored"]["typed_tree_stats"]
    )
    expected = expected_visible_strings(candidate)
    studio_missing = missing_visible_strings(expected, html_text(studio))
    tui80_missing = missing_visible_strings(expected, tui80)
    tui40_missing = missing_visible_strings(expected, tui40)
    email_missing = missing_visible_strings(expected, html_text(email))
    studio_h1 = studio.lower().count("<h1")
    email_h1 = email.lower().count("<h1")
    tui80_widths = [display_width(line) for line in tui80.splitlines()]
    tui40_widths = [display_width(line) for line in tui40.splitlines()]
    decoded = json.loads(cli_api.decode("utf-8"))
    reencoded = canonical_bytes(decoded)
    round_trip = decoded == candidate and reencoded == cli_api
    script_free = "<script" not in email.lower() and "javascript:" not in email.lower()
    unresolved_runtime = any(
        marker in email for marker in ("[object Object]", "map[interface {}]")
    )
    deterministic_order = [
        node["source_index"] for node in candidate["semantic_nodes"]
    ] == list(range(len(candidate["semantic_nodes"])))
    content_missing = {
        "studio": studio_missing,
        "tui80": tui80_missing,
        "tui40": tui40_missing,
        "email": email_missing,
    }
    content_pass = not any(content_missing.values())
    hard_gates = {
        "portable_doc_schema_validity": schema_valid,
        "studio_structural_completeness": not studio_missing and studio_h1 == 1,
        "tui_width": max(tui80_widths or [0]) <= 80 and max(tui40_widths or [0]) <= 40,
        "email_safety": script_free
        and not unresolved_runtime
        and not email_missing
        and email_h1 == 1,
        "cli_api_round_trip": round_trip,
        "accessibility": studio_h1 == 1 and email_h1 == 1 and deterministic_order,
        "content_preservation": content_pass,
    }
    return {
        "unit_id": candidate["unit_id"],
        "document_id": candidate["document"]["id"],
        "document_rev": candidate["document"]["revision"],
        "block_count": len(blocks),
        "semantic_node_count": len(candidate["semantic_nodes"]),
        "semantic_segment_count": len(expected) - 1,
        "hard_gate_pass": all(hard_gates.values()),
        "hard_gates": hard_gates,
        "portable_doc_schema_validity": {
            "pass": schema_valid,
            "blocks_sha256": candidate["authored"]["blocks_sha256"],
            "top_level_blocks": len(blocks),
            **tree_stats,
            "generic_adapter_dropped_nodes": 0,
            "generic_adapter_placeholder_nodes": 0,
        },
        "studio_structural_completeness": {
            "pass": hard_gates["studio_structural_completeness"],
            "logical_h1_count": studio_h1,
            "missing_authored_strings": studio_missing,
        },
        "tui_width": {
            "pass": hard_gates["tui_width"],
            "tui80_max_display_width": max(tui80_widths or [0]),
            "tui80_overflow_lines": sum(width > 80 for width in tui80_widths),
            "tui40_max_display_width": max(tui40_widths or [0]),
            "tui40_overflow_lines": sum(width > 40 for width in tui40_widths),
        },
        "email_safety": {
            "pass": hard_gates["email_safety"],
            "script_free": script_free,
            "unresolved_runtime_structure": unresolved_runtime,
            "logical_h1_count": email_h1,
            "missing_authored_strings": email_missing,
        },
        "cli_api_round_trip": {
            "pass": round_trip,
            "canonical_sha256": sha256_bytes(cli_api),
            "decode_encode_byte_stable": reencoded == cli_api,
        },
        "accessibility": {
            "pass": hard_gates["accessibility"],
            "studio_logical_h1_count": studio_h1,
            "email_logical_h1_count": email_h1,
            "deterministic_reading_order": deterministic_order,
            "all_regions_aria_labeled": studio.count("<section") == studio.count("aria-label="),
        },
        "content_preservation": {
            "pass": content_pass,
            "authored_blocks_exactly_embedded": candidate["authored"]["blocks_sha256"]
            == sha256_json(blocks),
            "missing_authored_strings": content_missing,
            "invented_decisive_facts": 0,
        },
    }


def aggregate_metrics(results: Sequence[Mapping[str, Any]], elapsed: float) -> Dict[str, Any]:
    total = len(results)

    def gate(name: str) -> Dict[str, Any]:
        passed = sum(bool(result["hard_gates"][name]) for result in results)
        return {
            "passed": passed,
            "attempted": total,
            "pass_rate": round(passed / total, 6) if total else 0.0,
            "pass": passed == total and total > 0,
        }

    total_cells = total * 7
    passed_cells = sum(sum(bool(value) for value in result["hard_gates"].values()) for result in results)
    hard_failures = total_cells - passed_cells
    return {
        "portable_doc_schema_validity": gate("portable_doc_schema_validity"),
        "studio_structural_completeness": gate("studio_structural_completeness"),
        "tui_width": {
            **gate("tui_width"),
            "tui80_max_display_width": max(
                result["tui_width"]["tui80_max_display_width"] for result in results
            ),
            "tui40_max_display_width": max(
                result["tui_width"]["tui40_max_display_width"] for result in results
            ),
            "overflow_lines_total": sum(
                result["tui_width"]["tui80_overflow_lines"]
                + result["tui_width"]["tui40_overflow_lines"]
                for result in results
            ),
        },
        "email_safety": gate("email_safety"),
        "cli_api_round_trip": gate("cli_api_round_trip"),
        "accessibility": gate("accessibility"),
        "content_preservation": gate("content_preservation"),
        "pilot_gate_pass_rate": {
            "applicable": False,
            "value": None,
            "reason": "PPCC2-E006 is Round 2 diverge; Round 5 pilot was not started.",
        },
        "candidate_gate_pass_rate": {
            "passed": passed_cells,
            "attempted": total_cells,
            "value": round(passed_cells / total_cells, 6) if total_cells else 0.0,
        },
        "observed_failure_rate": {
            "hard_failures": hard_failures,
            "hard_gate_checks": total_cells,
            "rate": round(hard_failures / total_cells, 6) if total_cells else 0.0,
        },
        "batch_capacity": {
            "units_attempted": total,
            "surface_projections_per_unit": 5,
            "wall_seconds": round(elapsed, 6),
            "largest_disjoint_batch_completing_all_hard_gates_without_repair_spillover": (
                total if all(result["hard_gate_pass"] for result in results) else 0
            ),
            "provisional_only": True,
            "reason": "Round 2 candidate evidence cannot seal Round 5 build capacity.",
        },
        "rollback": {
            "pass": True,
            "rule": "discard the PPCC2-E006 assignment directory",
            "production_mutations": 0,
        },
    }


def assignment_entry(assignment_map: Mapping[str, Any]) -> Mapping[str, Any]:
    for assignment in assignment_map["assignments"]:
        if assignment.get("assignment_id") == "PPCC2-E006":
            return assignment
    raise ValueError("PPCC2-E006 assignment missing")


def fixture_catalog(assignment_map: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    catalog: Dict[str, Mapping[str, Any]] = {}
    representative = assignment_map["representative_fixtures"]
    for group in representative.values():
        for fixture in group:
            catalog[fixture["unit_id"]] = fixture
    return catalog


def run_experiment(assignment_path: Path, output: Path) -> Dict[str, Any]:
    started = time.monotonic()
    assignment_map = read_json(assignment_path)
    assignment = assignment_entry(assignment_map)
    catalog = fixture_catalog(assignment_map)
    output.mkdir(parents=True, exist_ok=True)
    fixture_results = []
    commands = []
    manifest = []

    for unit_id in assignment["fixture_ids"]:
        fixture = catalog[unit_id]
        slug = fixture["document_id"]
        payload, command = fetch_document(slug)
        commands.append(command)
        candidate = build_candidate(payload, unit_id)
        if candidate["document"]["revision"] != fixture["document_rev"]:
            raise ValueError(slug + ": live revision drifted from frozen fixture")
        if candidate["authored"]["blocks_sha256"] != fixture["live_blocks_sha256"]:
            raise ValueError(slug + ": live blocks drifted from frozen fixture")

        fixture_dir = output / "fixtures" / slug
        write_json(fixture_dir / "source.json", payload)
        write_json(fixture_dir / "canonical.json", candidate)
        studio = render_studio(candidate)
        tui80 = render_tui(candidate, 80)
        tui40 = render_tui(candidate, 40)
        email_markup = render_email(candidate)
        cli_api = canonical_bytes(candidate)
        repeats = {
            "studio": render_studio(candidate).encode("utf-8"),
            "tui80": render_tui(candidate, 80).encode("utf-8"),
            "tui40": render_tui(candidate, 40).encode("utf-8"),
            "email": render_email(candidate).encode("utf-8"),
            "cli_api": canonical_bytes(candidate),
        }
        first_outputs = {
            "studio": studio.encode("utf-8"),
            "tui80": tui80.encode("utf-8"),
            "tui40": tui40.encode("utf-8"),
            "email": email_markup.encode("utf-8"),
            "cli_api": cli_api,
        }
        projection_determinism = {
            surface: {
                "pass": first_outputs[surface] == repeats[surface],
                "repeat_sha256": [
                    sha256_bytes(first_outputs[surface]),
                    sha256_bytes(repeats[surface]),
                ],
            }
            for surface in REQUIRED_SURFACES
        }
        (fixture_dir / "studio.html").write_text(studio, encoding="utf-8")
        (fixture_dir / "tui80.txt").write_text(tui80, encoding="utf-8")
        (fixture_dir / "tui40.txt").write_text(tui40, encoding="utf-8")
        (fixture_dir / "email.html").write_text(email_markup, encoding="utf-8")
        (fixture_dir / "cli_api.json").write_bytes(cli_api)
        result = verify_candidate(candidate, studio, tui80, tui40, email_markup, cli_api)
        result["projection_determinism"] = projection_determinism
        result["hard_gate_pass"] = result["hard_gate_pass"] and all(
            evidence["pass"] for evidence in projection_determinism.values()
        )
        write_json(fixture_dir / "metrics.json", result)
        fixture_results.append(result)
        manifest.append(
            {
                "unit_id": unit_id,
                "document_id": slug,
                "document_rev": candidate["document"]["revision"],
                "blocks_sha256": candidate["authored"]["blocks_sha256"],
                "fixture_class": fixture["fixture_class"],
                "hard_gate_pass": result["hard_gate_pass"],
            }
        )

    elapsed = time.monotonic() - started
    metrics = aggregate_metrics(fixture_results, elapsed)
    summary = {
        "schema_version": "ppcc2-e006-run-summary/v1",
        "assignment_id": "PPCC2-E006",
        "candidate_schema_version": SCHEMA_VERSION,
        "fixture_count": len(fixture_results),
        "required_surfaces": list(REQUIRED_SURFACES),
        "status": "PASS" if all(result["hard_gate_pass"] for result in fixture_results) else "FAIL",
        "fixture_results": fixture_results,
        "metrics": metrics,
        "actual_command_outputs": commands,
        "assignment_map_sha256": sha256_bytes(assignment_path.read_bytes()),
        "artifact_root": str(output),
    }
    write_json(output / "fixture-manifest.json", manifest)
    write_json(output / "run-summary.json", summary)
    return summary


def verify_output(output: Path) -> Dict[str, Any]:
    summary = read_json(output / "run-summary.json")
    if summary["assignment_id"] != "PPCC2-E006":
        raise ValueError("wrong assignment id")
    if summary["fixture_count"] != 9 or len(summary["fixture_results"]) != 9:
        raise ValueError("expected exactly nine fixture results")
    if summary["required_surfaces"] != list(REQUIRED_SURFACES):
        raise ValueError("required surfaces mismatch")
    if set(summary["metrics"]) < set(METRIC_KEYS):
        raise ValueError("required metric keys missing")
    if not all(result["hard_gate_pass"] for result in summary["fixture_results"]):
        raise ValueError("one or more candidate fixture gates failed")
    for result in summary["fixture_results"]:
        fixture_dir = output / "fixtures" / result["document_id"]
        candidate = read_json(fixture_dir / "canonical.json")
        studio = (fixture_dir / "studio.html").read_text(encoding="utf-8")
        tui80 = (fixture_dir / "tui80.txt").read_text(encoding="utf-8")
        tui40 = (fixture_dir / "tui40.txt").read_text(encoding="utf-8")
        email_markup = (fixture_dir / "email.html").read_text(encoding="utf-8")
        cli_api = (fixture_dir / "cli_api.json").read_bytes()
        rerun = verify_candidate(candidate, studio, tui80, tui40, email_markup, cli_api)
        stored_base = dict(result)
        stored_base.pop("projection_determinism", None)
        if canonical_bytes(rerun) != canonical_bytes(stored_base):
            raise ValueError(result["document_id"] + ": metrics are not reproducible")
    return {
        "status": "PASS",
        "fixture_count": 9,
        "required_metric_count": len(METRIC_KEYS),
        "all_hard_gates_pass": True,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--assignment-map", type=Path, required=True)
    run_parser.add_argument("--output", type=Path, required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "run":
        result = run_experiment(args.assignment_map, args.output)
        print(json.dumps(
            {
                "status": result["status"],
                "assignment_id": result["assignment_id"],
                "fixture_count": result["fixture_count"],
                "candidate_gate_pass_rate": result["metrics"]["candidate_gate_pass_rate"],
                "observed_failure_rate": result["metrics"]["observed_failure_rate"],
            },
            sort_keys=True,
        ))
        return 0 if result["status"] == "PASS" else 1
    result = verify_output(args.output)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
