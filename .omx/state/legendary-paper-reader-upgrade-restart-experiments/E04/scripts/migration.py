#!/usr/bin/env python3
"""Deterministic revision-fenced write-time migration candidate."""

from __future__ import annotations

import copy
import hashlib
import json
from typing import Any


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def digest(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def migrate(document: dict[str, Any], expected_revision: str) -> tuple[dict[str, Any], dict[str, Any]]:
    observed = document.get("_rev")
    receipt: dict[str, Any] = {
        "schema_version": "legendary-paper-restart-e04-migration-receipt/v1",
        "expected_revision": expected_revision,
        "observed_revision": observed,
        "preimage_sha256": digest(document),
        "actions": [],
        "quarantine": [],
        "boundaries": [],
    }
    if observed != expected_revision:
        receipt["status"] = "QUARANTINED_REVISION_MISMATCH"
        receipt["quarantine"].append({"path": "$", "reason": "revision_mismatch"})
        receipt["postimage_sha256"] = receipt["preimage_sha256"]
        return copy.deepcopy(document), receipt

    migrated = copy.deepcopy(document)

    def walk(value: Any, path: str) -> None:
        if isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, f"{path}[{index}]")
            return
        if not isinstance(value, dict):
            return
        if value.get("type") == "table":
            has_header = "header" in value
            has_head = "head" in value
            if not has_header and not has_head:
                receipt["boundaries"].append({"path": path, "kind": "headerless_table_retained"})
            elif has_header and not isinstance(value.get("header"), list):
                receipt["quarantine"].append({"path": path, "reason": "malformed_header_alias"})
            elif has_head and not isinstance(value.get("head"), list):
                receipt["quarantine"].append({"path": path, "reason": "malformed_head_alias"})
            elif has_header and has_head and value["header"] != value["head"]:
                receipt["quarantine"].append({"path": path, "reason": "conflicting_header_aliases"})
            elif has_header:
                before = digest(value)
                value["head"] = copy.deepcopy(value["header"])
                del value["header"]
                receipt["actions"].append({
                    "path": path,
                    "action": "canonicalize_header_to_head",
                    "before_sha256": before,
                    "after_sha256": digest(value),
                    "authored_header_cells": len(value["head"]),
                })
        if value.get("type") == "paragraph" and value.get("content") == []:
            receipt["boundaries"].append({"path": path, "kind": "exact_empty_spacer_retained"})
        for key in sorted(value):
            walk(value[key], f"{path}.{key}")

    walk(migrated.get("blocks", []), "$.blocks")
    receipt["status"] = "QUARANTINED_AMBIGUITY" if receipt["quarantine"] else "MIGRATED"
    receipt["postimage_sha256"] = digest(migrated)
    return migrated, receipt
