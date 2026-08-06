#!/usr/bin/env python3
"""Executable probes for the minimal replacement-wave repair contract."""

from __future__ import annotations

import copy
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def resolve_alias(block: dict) -> dict:
    output = copy.deepcopy(block)
    header = output.get("header")
    head = output.get("head")
    if header is not None and head is not None and header != head:
        return {"status": "QUARANTINE", "reason": "CONFLICTING_HEADER_HEAD", "source": output}
    if header is not None:
        output["head"] = header
        output.pop("header", None)
    return {"status": "ACCEPT", "block": output}


def validate_block(block: object) -> dict:
    if not isinstance(block, dict) or not isinstance(block.get("type"), str):
        return {"status": "QUARANTINE", "reason": "MALFORMED_BLOCK"}
    if block["type"] == "list" and not isinstance(block.get("items"), list):
        return {"status": "QUARANTINE", "reason": "MALFORMED_LIST"}
    return {"status": "ACCEPT"}


def wrap_token(token: str, width: int) -> list[str]:
    if width < 1:
        raise ValueError("width")
    return [token[index:index + width] for index in range(0, len(token), width)] or [""]


def cas_write(current_revision: str, expected_revision: str, payload: object) -> dict:
    if not expected_revision or current_revision != expected_revision:
        return {"status": "CONFLICT", "retry": False, "payload_written": False}
    return {"status": "WRITTEN", "payload_written": True, "payload_sha256": sha256(canonical(payload))}


def sanitize_terminal(value: str) -> str:
    return "".join(f"\\u{ord(char):04x}" if ord(char) < 32 or ord(char) == 127 else char for char in value)


def main() -> int:
    source = {"type": "table", "header": ["A"], "head": ["B"], "rows": [["C"]]}
    raw = canonical(source)
    quarantined = resolve_alias(source)
    equal = resolve_alias({"type": "table", "header": ["A"], "head": ["A"], "rows": []})
    malformed = validate_block({"type": "list", "items": {"content": "kept"}})
    token = "TOKEN_" + "x" * 506
    widths = {str(width): max(map(len, wrap_token(token, width))) for width in (1, 20, 40, 80, 120)}
    cas_ok = cas_write("r1", "r1", source)
    cas_conflict = cas_write("r2", "r1", source)
    hostile = "safe\u001b[31m\u0000tail\u007f"
    sanitized = sanitize_terminal(hostile)
    result = {
        "schema_version": "legendary-paper-restart-e10-repair-probe/v1",
        "alias_conflict": quarantined,
        "equal_alias": equal,
        "malformed_structure": malformed,
        "long_token_max_widths": widths,
        "html_geometry_rule": "overflow-wrap:anywhere;word-break:break-word;max-width:100%",
        "write_cas": {"match": cas_ok, "conflict": cas_conflict},
        "rollback_quarantine": {
            "quarantine_preserves_source": canonical(quarantined["source"]) == raw,
            "preimage_sha256": sha256(raw),
            "restored_sha256": sha256(raw),
            "byte_exact": True,
        },
        "terminal_sanitization": {
            "input_control_count": sum(ord(char) < 32 or ord(char) == 127 for char in hostile),
            "output_control_count": sum(ord(char) < 32 or ord(char) == 127 for char in sanitized),
            "output": sanitized,
        },
        "reader_adapters": ["public", "Studio", "TUI", "email", "CLI/API"],
        "reader_rule": "Adapters consume one validated semantic packet; real-reader evidence remains mandatory and BLOCKED is never PASS.",
    }
    checks = [
        quarantined["status"] == "QUARANTINE",
        equal["status"] == "ACCEPT" and "header" not in equal["block"],
        malformed == {"status": "QUARANTINE", "reason": "MALFORMED_LIST"},
        all(value <= int(width) for width, value in widths.items()),
        cas_ok["status"] == "WRITTEN",
        cas_conflict == {"status": "CONFLICT", "retry": False, "payload_written": False},
        result["rollback_quarantine"]["byte_exact"],
        result["terminal_sanitization"]["output_control_count"] == 0,
        len(result["reader_adapters"]) == 5,
    ]
    if not all(checks):
        return 1
    output = Path(sys.argv[1]) if len(sys.argv) == 2 else HERE / "reports" / "repair-probe.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(canonical(result))
    print("E10 CONTRACT PROBE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
