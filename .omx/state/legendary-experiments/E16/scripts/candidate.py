#!/usr/bin/env python3
"""Lossless source-backed semantic tree used by the isolated E16 candidate."""

from __future__ import annotations

import hashlib
import json
from copy import deepcopy
from typing import Any

SCHEMA_VERSION = "legendary-e16-lossless-semantic-tree/v1"
CANDIDATE_ID = "candidate-lossless-semantic-tree"
STRUCTURAL_TYPES = {
    "heading": "heading",
    "h1": "heading",
    "h2": "heading",
    "h3": "heading",
    "h4": "heading",
    "h5": "heading",
    "h6": "heading",
    "list": "list",
    "bullet_list": "list",
    "ordered_list": "list",
    "list_item": "list_item",
    "table": "table",
    "table_row": "table_row",
    "table_cell": "table_cell",
    "link": "link",
    "status": "status",
}
STATUS_KEYS = {"status", "lifecycle_status", "state"}
LINK_KEYS = {"href", "url"}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def semantic_hash(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def _path(parent: str, key: str | int) -> str:
    return f"{parent}[{key}]" if isinstance(key, int) else f"{parent}.{key}"


def encode_tree(value: Any, path: str = "$") -> dict[str, Any]:
    """Encode every source value without normalization; restore_tree is its inverse."""
    if isinstance(value, dict):
        raw_type = value.get("type")
        role = STRUCTURAL_TYPES.get(raw_type.casefold()) if isinstance(raw_type, str) else None
        return {
            "kind": "object",
            "path": path,
            "semantic_role": role,
            "entries": [
                {
                    "key": key,
                    "semantic_role": (
                        "status" if key.casefold() in STATUS_KEYS else
                        "link" if key.casefold() in LINK_KEYS else None
                    ),
                    "value": encode_tree(item, _path(path, key)),
                }
                for key, item in value.items()
            ],
        }
    if isinstance(value, list):
        return {
            "kind": "sequence",
            "path": path,
            "items": [encode_tree(item, _path(path, index)) for index, item in enumerate(value)],
        }
    if isinstance(value, str):
        return {
            "kind": "text",
            "path": path,
            "value": value,
            "codepoints": len(value),
            "utf8_bytes": len(value.encode()),
            "sha256": hashlib.sha256(value.encode()).hexdigest(),
        }
    if value is None:
        return {"kind": "null", "path": path, "value": None}
    if isinstance(value, bool):
        return {"kind": "boolean", "path": path, "value": value}
    if isinstance(value, (int, float)):
        return {"kind": "number", "path": path, "value": value}
    raise TypeError(f"unsupported source value at {path}: {type(value).__name__}")


def restore_tree(tree: dict[str, Any]) -> Any:
    kind = tree["kind"]
    if kind == "object":
        return {entry["key"]: restore_tree(entry["value"]) for entry in tree["entries"]}
    if kind == "sequence":
        return [restore_tree(item) for item in tree["items"]]
    return deepcopy(tree["value"])


def semantic_events(tree: dict[str, Any]) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []

    def walk(node: dict[str, Any], inherited_role: str | None = None) -> None:
        role = node.get("semantic_role") or inherited_role
        if node["kind"] == "object" and role:
            events.append({"ordinal": len(events), "role": role, "path": node["path"]})
        if node["kind"] == "text":
            events.append({
                "ordinal": len(events),
                "role": role or "text",
                "path": node["path"],
                "codepoints": node["codepoints"],
                "sha256": node["sha256"],
            })
        elif node["kind"] == "object":
            for entry in node["entries"]:
                walk(entry["value"], entry.get("semantic_role"))
        elif node["kind"] == "sequence":
            for item in node["items"]:
                walk(item)

    walk(tree)
    return events


def malformed_paths(value: Any, path: str = "$") -> list[str]:
    problems: list[str] = []
    if isinstance(value, dict):
        if "type" in value and not isinstance(value["type"], str):
            problems.append(f"{path}.type:expected_string")
        for key in ("blocks", "children", "content", "items", "rows"):
            if key in value and not isinstance(value[key], (list, str)):
                problems.append(f"{path}.{key}:expected_list_or_text")
        for key, item in value.items():
            problems.extend(malformed_paths(item, _path(path, key)))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            problems.extend(malformed_paths(item, _path(path, index)))
    return problems


def build_capsule(source: dict[str, Any], *, fixture_id: str, unit_type: str, cohort: str) -> dict[str, Any]:
    if source.get("schema_version") == SCHEMA_VERSION:
        return deepcopy(source)
    original = deepcopy(source)
    tree = encode_tree(original)
    restored = restore_tree(tree)
    events = semantic_events(tree)
    problems = malformed_paths(original)
    authored_path_markers = (
        ".body", ".blocks", ".content", ".children", ".items", ".rows",
        ".text", ".value", ".title", ".description", ".brief",
    )
    empty = not any(
        event["role"] == "text"
        and event.get("codepoints", 0)
        and any(marker in event["path"] for marker in authored_path_markers)
        for event in events
    )
    quarantine_reasons = problems + (["empty_authored_payload"] if empty else [])
    return {
        "schema_version": SCHEMA_VERSION,
        "candidate_id": CANDIDATE_ID,
        "fixture_id": fixture_id,
        "unit_type": unit_type,
        "cohort": cohort,
        "status": "quarantined_preserved" if quarantine_reasons else "preserved",
        "authority": {"source_of_truth": "source", "derived_tree_authoritative": False},
        "source": original,
        "source_sha256": semantic_hash(original),
        "semantic_tree": tree,
        "semantic_tree_sha256": semantic_hash(tree),
        "semantic_events": events,
        "semantic_events_sha256": semantic_hash(events),
        "round_trip_sha256": semantic_hash(restored),
        "quarantine_reasons": quarantine_reasons,
        "rollback": {"operation": "restore_tree", "expected_source_sha256": semantic_hash(original)},
    }
