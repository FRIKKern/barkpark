#!/usr/bin/env python3
"""One deterministic canonicalizer with explicit raw, envelope, and semantic boundaries."""

from __future__ import annotations

import hashlib
import json
import sys
import unicodedata
from pathlib import Path
from typing import Any


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize_text(value: str) -> str:
    """NFC only: do not collapse, trim, case-fold, or alter authored punctuation."""
    return unicodedata.normalize("NFC", value)


def nfc_tree(value: Any) -> Any:
    if isinstance(value, str):
        return normalize_text(value)
    if isinstance(value, list):
        return [nfc_tree(item) for item in value]
    if isinstance(value, dict):
        return {key: nfc_tree(item) for key, item in value.items()}
    return value


def canonicalize(data: bytes, boundary: str) -> dict[str, Any]:
    raw = {"bytes": len(data), "sha256": sha256(data)}
    if boundary == "raw":
        return {"boundary": "raw", "raw": raw}

    envelope = json.loads(data)
    envelope_bytes = canonical_bytes(envelope)
    if boundary == "envelope":
        return {
            "boundary": "envelope",
            "raw": raw,
            "canonical_bytes": len(envelope_bytes),
            "canonical_sha256": sha256(envelope_bytes),
            "value": envelope,
        }

    if boundary != "semantic":
        raise ValueError(f"unknown boundary: {boundary}")
    blocks = envelope.get("blocks")
    if not isinstance(blocks, list):
        raise ValueError("semantic boundary requires a JSON object with a blocks list")
    normalized_blocks = nfc_tree(blocks)
    semantic = {
        "identity": {
            "_id": envelope.get("_id"),
            "_publishedId": envelope.get("_publishedId"),
            "_rev": envelope.get("_rev"),
            "_type": envelope.get("_type"),
        },
        "authored_metadata": {
            "description": nfc_tree(envelope.get("description")),
            "main_tag": nfc_tree(envelope.get("main_tag")),
            "style": nfc_tree(envelope.get("style")),
            "tags": nfc_tree(envelope.get("tags")),
            "title": nfc_tree(envelope.get("title")),
        },
        "blocks": normalized_blocks,
    }
    semantic_bytes = canonical_bytes(semantic)
    return {
        "boundary": "semantic",
        "raw": raw,
        "envelope_canonical_sha256": sha256(envelope_bytes),
        "semantic_bytes": len(semantic_bytes),
        "semantic_sha256": sha256(semantic_bytes),
        "normalization": "Unicode NFC recursively; no trimming, whitespace collapse, case-folding, punctuation change, field aliasing, header inference, or block reordering",
        "excluded_as_derived_or_transport": ["_createdAt", "_draft", "_updatedAt", "body", "body_html", "body_html_sv", "preview"],
        "value": semantic,
    }


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: canonicalizer.py raw|envelope|semantic INPUT")
    result = canonicalize(Path(sys.argv[2]).read_bytes(), sys.argv[1])
    sys.stdout.buffer.write(canonical_bytes(result) + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
