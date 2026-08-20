#!/usr/bin/env python3
"""Deterministic preservation-first compatibility envelope for E05."""

from __future__ import annotations

import hashlib
import html
import json
import re
import textwrap
from copy import deepcopy
from typing import Any


SCHEMA_VERSION = "legendary-e05-preservation-envelope/v1"
CANDIDATE_ID = "candidate-preservation-envelope"
SURFACES = ("Studio", "public paper reader", "TUI", "CLI/API", "email")
BLOCK_TAGS = re.compile(r"</?(?:p|div|br|li|h[1-6]|tr|blockquote)[^>]*>", re.I)
ANY_TAG = re.compile(r"<[^>]+>")


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def semantic_hash(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def _clean_text(value: str) -> str:
    return "\n".join(line.rstrip() for line in value.replace("\r\n", "\n").splitlines()).strip()


def _html_to_text(value: str) -> str:
    spaced = BLOCK_TAGS.sub("\n", value)
    text = _clean_text(html.unescape(ANY_TAG.sub("", spaced)))
    return re.sub(r"\n{2,}", "\n", text)


def _portable_text(value: Any, problems: list[str], path: str = "$") -> list[str]:
    """Extract semantic text without silently accepting structurally malformed nodes."""
    if value is None:
        return []
    if isinstance(value, str):
        cleaned = _clean_text(value)
        return [cleaned] if cleaned else []
    if isinstance(value, (int, float, bool)):
        return [str(value)]
    if isinstance(value, list):
        parts: list[str] = []
        for index, item in enumerate(value):
            parts.extend(_portable_text(item, problems, f"{path}[{index}]"))
        return parts
    if not isinstance(value, dict):
        problems.append(f"{path}: unsupported value type {type(value).__name__}")
        return []

    node_type = value.get("type")
    if node_type is not None and not isinstance(node_type, str):
        problems.append(f"{path}.type: expected string")
    for key in ("children", "content", "items", "rows", "blocks"):
        if key in value and not isinstance(value[key], list):
            problems.append(f"{path}.{key}: expected list")

    parts: list[str] = []
    for key in ("text", "value", "label", "title"):
        if isinstance(value.get(key), str):
            cleaned = _clean_text(value[key])
            if cleaned:
                parts.append(cleaned)
    for key in ("content", "children", "items", "rows", "blocks"):
        if isinstance(value.get(key), list):
            parts.extend(_portable_text(value[key], problems, f"{path}.{key}"))
    return parts


def _candidate_sources(source: dict[str, Any], unit_type: str) -> list[tuple[str, Any, str]]:
    if unit_type == "task":
        return [
            ("brief.blocks", (source.get("brief") or {}).get("blocks") if isinstance(source.get("brief"), dict) else None, "portable"),
            ("description", source.get("description"), "markdown"),
            ("title", source.get("title"), "text"),
        ]
    body = source.get("body")
    content = source.get("content")
    return [
        ("blocks", source.get("blocks"), "portable"),
        ("content.blocks", content.get("blocks") if isinstance(content, dict) else None, "portable"),
        ("body.blocks", body.get("blocks") if isinstance(body, dict) else None, "portable"),
        ("body_html", source.get("body_html"), "html"),
        ("body", body if isinstance(body, str) else None, "markdown"),
        ("description", source.get("description"), "markdown"),
        ("content", content if isinstance(content, str) else None, "markdown"),
        ("title", source.get("title"), "text"),
    ]


def choose_authoritative_view(source: dict[str, Any], unit_type: str) -> dict[str, Any]:
    candidates = _candidate_sources(source, unit_type)
    populated: list[str] = []
    selected: dict[str, Any] | None = None

    for path, value, kind in candidates:
        if value in (None, "", [], {}):
            continue
        problems: list[str] = []
        if kind == "portable":
            parts = _portable_text(value, problems, path)
            rendered = _clean_text("\n".join(parts))
        elif kind == "html" and isinstance(value, str):
            rendered = _html_to_text(value)
        elif isinstance(value, str):
            rendered = _clean_text(value)
        else:
            rendered = ""
            problems.append(f"{path}: unsupported source shape")

        populated.append(path)
        if selected is None:
            selected = {
                "path": path,
                "kind": kind,
                "text": rendered,
                "problems": problems,
            }

    if selected is None:
        return {
            "status": "supported_error",
            "error": "empty_source",
            "message": "Supported error: source contains no renderable authored payload.",
            "authoritative_source_path": None,
            "populated_source_paths": [],
            "conflicts": [],
        }

    if selected["problems"]:
        return {
            "status": "supported_error",
            "error": "malformed_authoritative_source",
            "message": "Supported error: authoritative source is malformed and was quarantined.",
            "authoritative_source_path": selected["path"],
            "populated_source_paths": populated,
            "conflicts": populated[1:],
            "problems": selected["problems"],
        }
    if not selected["text"]:
        return {
            "status": "supported_error",
            "error": "blank_authoritative_source",
            "message": "Supported error: authoritative source produced no semantic text.",
            "authoritative_source_path": selected["path"],
            "populated_source_paths": populated,
            "conflicts": populated[1:],
        }
    return {
        "status": "renderable",
        "authoritative_source_path": selected["path"],
        "authoritative_kind": selected["kind"],
        "populated_source_paths": populated,
        "conflicts": populated[1:],
        "text": selected["text"],
    }


def _surface_views(view: dict[str, Any]) -> dict[str, dict[str, str]]:
    if view["status"] == "supported_error":
        text = view["message"]
        mode = "explicit_supported_error"
    else:
        text = view["text"]
        mode = "derived_from_authoritative_source"
    escaped = html.escape(text)
    return {
        "Studio": {"mode": mode, "output": f"<article>{escaped}</article>"},
        "public paper reader": {"mode": mode, "output": f"<article>{escaped}</article>"},
        "TUI": {
            "mode": mode,
            "output": "\n".join(textwrap.wrap(text, width=20, break_long_words=True, break_on_hyphens=False)) or text,
        },
        "CLI/API": {"mode": mode, "output": text},
        "email": {
            "mode": mode,
            "output": "\n".join(textwrap.wrap(text, width=72, break_long_words=True, break_on_hyphens=False)) or text,
        },
    }


def build_envelope(
    source: dict[str, Any], *, fixture_id: str, unit_type: str, cohort: str
) -> dict[str, Any]:
    if source.get("schema_version") == SCHEMA_VERSION:
        return deepcopy(source)

    preimage = deepcopy(source)
    view = choose_authoritative_view(preimage, unit_type)
    annotation: dict[str, Any] = {
        "authority": "advisory_only",
        "may_mutate_source": False,
    }
    if unit_type == "task":
        annotation["recommended_class"] = cohort
        annotation["requires_authority_and_evidence_gate"] = True

    return {
        "schema_version": SCHEMA_VERSION,
        "candidate_id": CANDIDATE_ID,
        "fixture_id": fixture_id,
        "unit_type": unit_type,
        "cohort": cohort,
        "authority": {
            "source_of_truth": "source",
            "derived_views_authoritative": False,
            "single_truth_count": 1,
        },
        "source": preimage,
        "provenance": {
            "source_semantic_sha256": semantic_hash(preimage),
            "authoritative_source_path": view.get("authoritative_source_path"),
            "populated_source_paths": view.get("populated_source_paths", []),
            "conflicts_reported_not_selected": view.get("conflicts", []),
            "fallback_precedence": [path for path, _, _ in _candidate_sources(preimage, unit_type)],
        },
        "reader_contract": view,
        "reader_views": _surface_views(view),
        "annotation": annotation,
        "rollback": {
            "operation": "remove_envelope_return_source",
            "expected_preimage_sha256": semantic_hash(preimage),
        },
    }


def remove_envelope(envelope: dict[str, Any]) -> dict[str, Any]:
    if envelope.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("not an E05 preservation envelope")
    return deepcopy(envelope["source"])
