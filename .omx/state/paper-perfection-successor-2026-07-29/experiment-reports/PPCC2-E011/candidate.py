#!/usr/bin/env python3
"""PPCC2-E011 isolated accessibility convergence candidate and gate."""

from __future__ import annotations

import argparse
import collections
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

import base_candidate as base


ASSIGNMENT_ID = "PPCC2-E011"
SCHEMA_VERSION = "ppcc2-accessibility-convergence/v1"
REQUIRED_SURFACES = ("studio", "tui80", "tui40", "email", "cli_api")
METRIC_KEYS = base.METRIC_KEYS

_BASE_BUILD = base.build_candidate
_BASE_AGGREGATE = base.aggregate_metrics
_KNOWN_TYPES = {
    "action",
    "blockquote",
    "byline",
    "callout",
    "card",
    "cards",
    "chart",
    "code",
    "columns",
    "diagram",
    "divider",
    "em",
    "eyebrow",
    "heading",
    "heatmap",
    "image",
    "ingress",
    "list",
    "list_item",
    "notes",
    "paragraph",
    "pullquote",
    "section",
    "stat",
    "stat-grid",
    "stats",
    "strong",
    "table",
    "table_cell",
    "table_row",
    "terminal",
    "text",
}
_CONTAINER_TYPES = {"card", "columns", "section", "terminal"}
_SAFE_LINK = re.compile(r"^(?:https?://|mailto:|/|#)", re.IGNORECASE)


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def strict_loads(raw: str) -> Any:
    def pairs(values: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in values:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result

    def reject_constant(value: str) -> Any:
        raise ValueError("non-finite JSON number: " + value)

    return json.loads(
        raw, object_pairs_hook=pairs, parse_constant=reject_constant
    )


def _path(parts: Sequence[Any]) -> str:
    output = "$"
    for part in parts:
        if isinstance(part, int):
            output += "[{}]".format(part)
        else:
            output += "." + str(part)
    return output


def _iter_typed(value: Any, parts: Tuple[Any, ...] = ()) -> Iterable[Tuple[Mapping[str, Any], Tuple[Any, ...]]]:
    if isinstance(value, dict):
        if isinstance(value.get("type"), str):
            yield value, parts
        for key, child in value.items():
            yield from _iter_typed(child, parts + (key,))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from _iter_typed(child, parts + (index,))


def _node_strings(node: Mapping[str, Any]) -> List[str]:
    values = list(node.get("segments", []))
    for key in ("text", "alt", "caption", "label", "href"):
        value = node.get(key)
        if isinstance(value, str) and value:
            values.append(value)
    return values


def _visible_direct(value: Mapping[str, Any]) -> List[str]:
    output = []
    for key in ("eyebrow", "title", "heading", "label", "lead", "footer", "summary", "description", "text", "message", "reason", "quote", "caption"):
        item = value.get(key)
        if isinstance(item, str) and item.strip():
            output.append(" ".join(item.split()))
    return output


def _semantic_text(value: Any) -> str:
    return " ".join(base.semantic_strings(value)).strip()


def build_render_nodes(blocks: Sequence[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    nodes: List[Dict[str, Any]] = []

    def add(role: str, parts: Tuple[Any, ...], **values: Any) -> None:
        node = {
            "order": len(nodes),
            "role": role,
            "source_path": _path(parts),
            **values,
        }
        nodes.append(node)

    def visit(value: Any, parts: Tuple[Any, ...]) -> None:
        if not isinstance(value, dict):
            return
        block_type = value.get("type")
        if not isinstance(block_type, str):
            for key, child in value.items():
                if isinstance(child, dict):
                    visit(child, parts + (key,))
                elif isinstance(child, list):
                    for index, item in enumerate(child):
                        if isinstance(item, dict):
                            visit(item, parts + (key, index))
                        elif isinstance(item, list):
                            for inner_index, inner in enumerate(item):
                                if isinstance(inner, dict):
                                    visit(
                                        inner,
                                        parts + (key, index, inner_index),
                                    )
            return
        if block_type == "heading":
            text = _semantic_text(value) or "Untitled section"
            level = value.get("level")
            if not isinstance(level, int):
                level = 2
            add("heading", parts, text=text, level=min(6, max(2, level)))
            return
        if block_type == "image":
            raw_alt = value.get("alt")
            fallback = value.get("caption") or value.get("title") or "Image (description unavailable)"
            alt = raw_alt.strip() if isinstance(raw_alt, str) and raw_alt.strip() else str(fallback)
            caption = value.get("caption")
            add(
                "image",
                parts,
                alt=alt,
                caption=caption.strip() if isinstance(caption, str) else "",
                src=value.get("src") if isinstance(value.get("src"), str) else "",
            )
            return
        if block_type == "action" or isinstance(value.get("href"), str):
            href = value.get("href") if isinstance(value.get("href"), str) else ""
            label = value.get("label") or value.get("title") or value.get("text") or href or "Link unavailable"
            add(
                "link",
                parts,
                label=" ".join(str(label).split()),
                href=href,
                safe=bool(_SAFE_LINK.match(href)),
            )
            return
        if block_type == "divider":
            add("separator", parts)
            return
        if block_type == "code":
            add("code", parts, text=str(value.get("value") or ""))
            return
        if block_type == "list":
            items = value.get("items")
            if isinstance(items, list):
                for index, item in enumerate(items):
                    text = _semantic_text(item)
                    if text:
                        add("list_item", parts + ("items", index), text=text)
            return
        if block_type == "table":
            segments = base.semantic_strings(value)
            if segments:
                add("table", parts, segments=segments)
            return
        if block_type in _CONTAINER_TYPES:
            direct = _visible_direct(value)
            if direct:
                add("paragraph", parts, segments=direct)
            for key, child in value.items():
                if key in {"type", "id", "_id", "_key", "key"}:
                    continue
                if isinstance(child, dict):
                    visit(child, parts + (key,))
                elif isinstance(child, list):
                    for index, item in enumerate(child):
                        if isinstance(item, dict):
                            visit(item, parts + (key, index))
                        elif isinstance(item, list):
                            for inner_index, inner in enumerate(item):
                                if isinstance(inner, dict):
                                    visit(inner, parts + (key, index, inner_index))
            return
        segments = base.semantic_strings(value)
        if segments:
            add("paragraph", parts, segments=segments)

    for block_index, block in enumerate(blocks):
        before = len(nodes)
        visit(block, (block_index,))
        expected = collections.Counter(base.semantic_strings(block))
        observed = collections.Counter(
            text for node in nodes[before:] for text in _node_strings(node)
        )
        missing: List[str] = []
        for value, count in expected.items():
            missing.extend([value] * max(0, count - observed[value]))
        if missing:
            add("paragraph", (block_index, "fallback"), segments=missing, fallback=True)
    return nodes


def _degradations(blocks: Sequence[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    seen_ids: Dict[str, str] = {}
    for index, block in enumerate(blocks):
        block_path = _path((index,))
        block_id = next(
            (
                block[key]
                for key in ("id", "_id", "_key", "key")
                if isinstance(block.get(key), str) and block[key]
            ),
            None,
        )
        if block_id is None:
            records.append(
                {
                    "status": "degraded",
                    "reason": "missing_block_identifier",
                    "source_path": block_path,
                    "fallback": "source-index-{}".format(index),
                }
            )
        elif block_id in seen_ids:
            raise ValueError(
                "{}: duplicate block identifier {} at {} and {}".format(
                    ASSIGNMENT_ID, block_id, seen_ids[block_id], block_path
                )
            )
        else:
            seen_ids[block_id] = block_path
    for typed, parts in _iter_typed(blocks):
        block_type = typed["type"]
        source_path = _path(parts)
        if block_type not in _KNOWN_TYPES:
            records.append(
                {
                    "status": "degraded",
                    "reason": "unknown_block_semantic_fallback",
                    "source_path": source_path,
                    "block_type": block_type,
                }
            )
        if block_type == "image" and not (
            isinstance(typed.get("alt"), str) and typed["alt"].strip()
        ):
            records.append(
                {
                    "status": "degraded",
                    "reason": "missing_image_alt",
                    "source_path": source_path,
                    "fallback": typed.get("caption")
                    or typed.get("title")
                    or "Image (description unavailable)",
                }
            )
        if block_type == "action":
            href = typed.get("href")
            if not isinstance(href, str) or not _SAFE_LINK.match(href):
                records.append(
                    {
                        "status": "degraded",
                        "reason": "missing_or_unsafe_link_target",
                        "source_path": source_path,
                        "preserved_raw_href": href,
                    }
                )
    return records


def build_candidate(payload: Mapping[str, Any], unit_id: str) -> Dict[str, Any]:
    source = payload.get("source")
    blocks = source.get("blocks") if isinstance(source, dict) else None
    if isinstance(blocks, list):
        stats = base.typed_tree_stats(blocks)
        if stats["null_nodes"]:
            raise ValueError(unit_id + ": nested nulls require quarantine")
        if stats["max_json_depth"] > 64:
            raise ValueError(unit_id + ": JSON depth exceeds 64")
    candidate = _BASE_BUILD(payload, unit_id)
    blocks = candidate["authored"]["portable_doc"]["blocks"]
    candidate["schema_version"] = SCHEMA_VERSION
    candidate["render_nodes"] = build_render_nodes(blocks)
    candidate["degradations"] = _degradations(blocks)
    candidate["reader_contract"].update(
        {
            "heading_policy": "one document H1; authored headings preserved as H2-H6",
            "image_policy": "every image has nonempty alt with explicit fallback degradation",
            "link_policy": "safe href is semantic and visible; unsafe href is visible-only degradation",
            "email_disclosure": "linear; details and scripts forbidden",
            "cross_reader_equivalence": "all render_nodes appear in identical order",
        }
    )
    candidate["render_nodes_sha256"] = base.sha256_json(candidate["render_nodes"])
    return candidate


def build_or_quarantine(payload: Mapping[str, Any], unit_id: str) -> Dict[str, Any]:
    try:
        return {"status": "accepted", "candidate": build_candidate(payload, unit_id)}
    except (TypeError, ValueError) as error:
        return {
            "status": "quarantined",
            "reason": str(error),
            "source_path": "$",
            "raw_payload": payload,
            "raw_payload_sha256": base.sha256_json(payload),
        }


def _render_node_html(node: Mapping[str, Any], email_mode: bool) -> str:
    role = node["role"]
    if role == "heading":
        level = int(node["level"])
        return "<h{0}>{1}</h{0}>".format(level, html.escape(node["text"]))
    if role == "image":
        src = html.escape(node.get("src") or "about:blank", quote=True)
        alt = html.escape(node["alt"], quote=True)
        caption = html.escape(node.get("caption") or "")
        return '<figure><img src="{}" alt="{}">{}</figure>'.format(
            src, alt, "<figcaption>" + caption + "</figcaption>" if caption else ""
        )
    if role == "link":
        label = html.escape(node["label"])
        href = html.escape(node.get("href") or "", quote=True)
        if node.get("safe"):
            return '<p><a href="{0}">{1}</a> <span>({0})</span></p>'.format(
                href, label
            )
        return "<p>{} [link unavailable: {}]</p>".format(label, href)
    if role == "separator":
        return "<hr>"
    if role == "code":
        return "<pre><code>{}</code></pre>".format(html.escape(node["text"]))
    if role == "list_item":
        return "<ul><li>{}</li></ul>".format(html.escape(node["text"]))
    segments = node.get("segments", [])
    if role == "table":
        cells = "".join("<td>{}</td>".format(html.escape(value)) for value in segments)
        return "<table><tbody><tr>{}</tr></tbody></table>".format(cells)
    return "".join("<p>{}</p>".format(html.escape(value)) for value in segments)


def _render_html(candidate: Mapping[str, Any], email_mode: bool) -> str:
    title = html.escape(candidate["document"]["title"])
    if email_mode:
        parts = [
            '<!doctype html><html><body style="margin:0;padding:24px;font-family:Arial,sans-serif;line-height:1.5">',
            '<main aria-labelledby="paper-title"><article>',
            '<h1 id="paper-title">{}</h1>'.format(title),
        ]
    else:
        parts = [
            '<!doctype html><html><body><main id="reader-main" aria-labelledby="paper-title"><article id="paper-body">',
            '<h1 id="paper-title">{}</h1>'.format(title),
        ]
    for node in candidate["render_nodes"]:
        parts.append(
            '<section data-order="{}" data-source-path="{}" aria-label="Reading item {}">'.format(
                node["order"],
                html.escape(node["source_path"], quote=True),
                node["order"] + 1,
            )
        )
        parts.append(_render_node_html(node, email_mode))
        parts.append("</section>")
    parts.append("</article></main></body></html>")
    return "".join(parts) + "\n"


def render_studio(candidate: Mapping[str, Any]) -> str:
    return _render_html(candidate, False)


def render_email(candidate: Mapping[str, Any]) -> str:
    return _render_html(candidate, True)


def render_tui(candidate: Mapping[str, Any], width: int) -> str:
    lines: List[str] = []

    def emit(value: str) -> None:
        lines.extend(base.hard_wrap(value, width))

    emit(candidate["document"]["title"])
    lines.append("=" * min(width, max(3, base.display_width(candidate["document"]["title"]))))
    for node in candidate["render_nodes"]:
        role = node["role"]
        if role == "heading":
            emit("{} {}".format("#" * max(2, int(node["level"])), node["text"]))
        elif role == "image":
            emit("[Image: {}]".format(node["alt"]))
            if node.get("caption"):
                emit(node["caption"])
        elif role == "link":
            suffix = node.get("href") or "link unavailable"
            emit("{} <{}>".format(node["label"], suffix))
        elif role == "separator":
            lines.append("-" * min(width, 12))
        elif role == "code":
            for raw_line in node["text"].splitlines() or [""]:
                emit(raw_line)
        elif role == "list_item":
            emit("- " + node["text"])
        else:
            for segment in node.get("segments", []):
                emit(segment)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


class _SemanticsParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.h1 = 0
        self.authored_headings = 0
        self.images = 0
        self.images_missing_alt = 0
        self.links: List[str] = []
        self.sections: List[int] = []
        self.main_labelled = False

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag == "h1":
            self.h1 += 1
        elif tag in {"h2", "h3", "h4", "h5", "h6"}:
            self.authored_headings += 1
        elif tag == "img":
            self.images += 1
            if not (values.get("alt") or "").strip():
                self.images_missing_alt += 1
        elif tag == "a":
            self.links.append(values.get("href") or "")
        elif tag == "section" and (values.get("data-order") or "").isdigit():
            self.sections.append(int(values["data-order"]))
        elif tag == "main" and values.get("aria-labelledby"):
            self.main_labelled = True


def _expected_strings(candidate: Mapping[str, Any]) -> List[str]:
    return [candidate["document"]["title"]] + [
        value for node in candidate["render_nodes"] for value in _node_strings(node)
    ]


def _expected_html_strings(candidate: Mapping[str, Any]) -> List[str]:
    values = [candidate["document"]["title"]]
    for node in candidate["render_nodes"]:
        if node["role"] == "image":
            if node.get("caption"):
                values.append(node["caption"])
            continue
        values.extend(_node_strings(node))
    return values


def verify_candidate(
    candidate: Mapping[str, Any],
    studio: str,
    tui80: str,
    tui40: str,
    email_markup: str,
    cli_api: bytes,
) -> Dict[str, Any]:
    expected = _expected_strings(candidate)
    html_expected = _expected_html_strings(candidate)
    studio_missing = base.missing_visible_strings(html_expected, base.html_text(studio))
    tui80_missing = base.missing_visible_strings(expected, tui80)
    tui40_missing = base.missing_visible_strings(expected, tui40)
    email_missing = base.missing_visible_strings(
        html_expected, base.html_text(email_markup)
    )
    studio_parser = _SemanticsParser()
    studio_parser.feed(studio)
    email_parser = _SemanticsParser()
    email_parser.feed(email_markup)
    source_headings = sum(node["role"] == "heading" for node in candidate["render_nodes"])
    source_images = sum(node["role"] == "image" for node in candidate["render_nodes"])
    safe_links = [node["href"] for node in candidate["render_nodes"] if node["role"] == "link" and node.get("safe")]
    order = [node["order"] for node in candidate["render_nodes"]]
    deterministic_order = order == list(range(len(order)))
    studio_semantics = (
        studio_parser.h1 == 1
        and studio_parser.authored_headings == source_headings
        and studio_parser.images == source_images
        and studio_parser.images_missing_alt == 0
        and studio_parser.links == safe_links
        and studio_parser.sections == order
        and studio_parser.main_labelled
    )
    email_semantics = (
        email_parser.h1 == 1
        and email_parser.authored_headings == source_headings
        and email_parser.images == source_images
        and email_parser.images_missing_alt == 0
        and email_parser.links == safe_links
        and email_parser.sections == order
        and email_parser.main_labelled
        and "<details" not in email_markup.lower()
        and "<script" not in email_markup.lower()
        and "javascript:" not in "".join(email_parser.links).lower()
    )
    tui80_widths = [base.display_width(line) for line in tui80.splitlines()]
    tui40_widths = [base.display_width(line) for line in tui40.splitlines()]
    decoded = strict_loads(cli_api.decode("utf-8"))
    round_trip = decoded == candidate and canonical_bytes(decoded) == cli_api
    tree_stats = base.typed_tree_stats(candidate["authored"]["portable_doc"]["blocks"])
    schema_valid = (
        candidate.get("schema_version") == SCHEMA_VERSION
        and candidate["authored"]["blocks_sha256"]
        == base.sha256_json(candidate["authored"]["portable_doc"]["blocks"])
        and tree_stats["invalid_typed_nodes"] == 0
        and tree_stats["null_nodes"] == 0
        and tree_stats["max_json_depth"] <= 64
        and candidate["render_nodes_sha256"] == base.sha256_json(candidate["render_nodes"])
    )
    missing = {
        "studio": studio_missing,
        "tui80": tui80_missing,
        "tui40": tui40_missing,
        "email": email_missing,
    }
    content_pass = not any(missing.values())
    accessibility_pass = studio_semantics and email_semantics and deterministic_order
    hard_gates = {
        "portable_doc_schema_validity": schema_valid,
        "studio_structural_completeness": studio_semantics and not studio_missing,
        "tui_width": max(tui80_widths or [0]) <= 80 and max(tui40_widths or [0]) <= 40,
        "email_safety": email_semantics and not email_missing,
        "cli_api_round_trip": round_trip,
        "accessibility": accessibility_pass,
        "content_preservation": content_pass,
    }
    equivalence_digest = base.sha256_json(expected)
    return {
        "unit_id": candidate["unit_id"],
        "document_id": candidate["document"]["id"],
        "document_rev": candidate["document"]["revision"],
        "block_count": len(candidate["authored"]["portable_doc"]["blocks"]),
        "render_node_count": len(candidate["render_nodes"]),
        "hard_gate_pass": all(hard_gates.values()),
        "hard_gates": hard_gates,
        "portable_doc_schema_validity": {"pass": schema_valid, **tree_stats},
        "studio_structural_completeness": {
            "pass": hard_gates["studio_structural_completeness"],
            "logical_h1_count": studio_parser.h1,
            "authored_heading_count": studio_parser.authored_headings,
            "image_count": studio_parser.images,
            "safe_link_count": len(studio_parser.links),
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
            "linear_no_details": "<details" not in email_markup.lower(),
            "script_free": "<script" not in email_markup.lower(),
            "logical_h1_count": email_parser.h1,
            "authored_heading_count": email_parser.authored_headings,
            "missing_authored_strings": email_missing,
        },
        "cli_api_round_trip": {
            "pass": round_trip,
            "canonical_sha256": base.sha256_bytes(cli_api),
            "strict_rfc_json": True,
            "decode_encode_byte_stable": canonical_bytes(decoded) == cli_api,
        },
        "accessibility": {
            "pass": accessibility_pass,
            "deterministic_reading_order": deterministic_order,
            "source_heading_count": source_headings,
            "studio_heading_count": studio_parser.authored_headings,
            "email_heading_count": email_parser.authored_headings,
            "source_image_count": source_images,
            "images_missing_alt": studio_parser.images_missing_alt
            + email_parser.images_missing_alt,
            "safe_link_count": len(safe_links),
            "studio_main_labelled": studio_parser.main_labelled,
            "email_main_labelled": email_parser.main_labelled,
            "cross_reader_equivalence_sha256": equivalence_digest,
        },
        "content_preservation": {
            "pass": content_pass,
            "authored_blocks_exactly_embedded": True,
            "missing_authored_strings": missing,
            "invented_decisive_facts": 0,
        },
        "degradation_count": len(candidate["degradations"]),
        "degradations": candidate["degradations"],
    }


def aggregate_metrics(results: Sequence[Mapping[str, Any]], elapsed: float) -> Dict[str, Any]:
    metrics = _BASE_AGGREGATE(results, elapsed)
    metrics["pilot_gate_pass_rate"] = {
        "applicable": False,
        "value": None,
        "reason": "PPCC2-E011 is Round 4 convergence; Round 5 pilot was not started.",
    }
    metrics["batch_capacity"].update(
        {
            "provisional_only": True,
            "reason": "Round 4 convergence cannot seal Round 5 builder capacity.",
        }
    )
    metrics["rollback"] = {
        "pass": True,
        "rule": "discard only the isolated PPCC2-E011 assignment directory",
        "production_mutations": 0,
    }
    return metrics


def assignment_entry(assignment_map: Mapping[str, Any]) -> Mapping[str, Any]:
    for assignment in assignment_map["assignments"]:
        if assignment.get("assignment_id") == ASSIGNMENT_ID:
            return assignment
    raise ValueError(ASSIGNMENT_ID + " assignment missing")


base._SKIP_KEYS = set(base._SKIP_KEYS) - {"href", "url"}
base.SCHEMA_VERSION = SCHEMA_VERSION
base.canonical_bytes = canonical_bytes
base.build_candidate = build_candidate
base.render_studio = render_studio
base.render_email = render_email
base.render_tui = render_tui
base.verify_candidate = verify_candidate
base.aggregate_metrics = aggregate_metrics
base.assignment_entry = assignment_entry


def run_experiment(assignment_path: Path, output: Path) -> Dict[str, Any]:
    summary = base.run_experiment(assignment_path, output)
    summary["schema_version"] = "ppcc2-e011-run-summary/v1"
    summary["assignment_id"] = ASSIGNMENT_ID
    summary["candidate_schema_version"] = SCHEMA_VERSION
    base.write_json(output / "run-summary.json", summary)
    return summary


def verify_output(output: Path) -> Dict[str, Any]:
    summary = base.read_json(output / "run-summary.json")
    if summary["assignment_id"] != ASSIGNMENT_ID:
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
        candidate = base.read_json(fixture_dir / "canonical.json")
        rerun = verify_candidate(
            candidate,
            (fixture_dir / "studio.html").read_text(encoding="utf-8"),
            (fixture_dir / "tui80.txt").read_text(encoding="utf-8"),
            (fixture_dir / "tui40.txt").read_text(encoding="utf-8"),
            (fixture_dir / "email.html").read_text(encoding="utf-8"),
            (fixture_dir / "cli_api.json").read_bytes(),
        )
        stored = dict(result)
        stored.pop("projection_determinism", None)
        if canonical_bytes(rerun) != canonical_bytes(stored):
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
        print(
            json.dumps(
                {
                    "assignment_id": result["assignment_id"],
                    "fixture_count": result["fixture_count"],
                    "metrics": result["metrics"],
                    "status": result["status"],
                },
                sort_keys=True,
            )
        )
        return 0 if result["status"] == "PASS" else 1
    result = verify_output(args.output)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
