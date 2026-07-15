#!/usr/bin/env python3
"""Redact ephemeral cookies/CSRF values while retaining pre-redaction hashes."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    existing_path = ROOT / "redaction-index.json"
    existing = {}
    if existing_path.exists():
        existing = {row["path"]: row for row in json.loads(existing_path.read_text()).get("files", [])}
    records = []
    candidates = sorted(path for path in (ROOT / "raw").rglob("*") if path.is_file() and path.name != "selected-source-documents.json")
    for path in candidates:
        original = path.read_bytes()
        text = original.decode("utf-8", errors="replace")
        redacted = re.sub(r"(?im)^set-cookie:\s*[^\r\n]+", "set-cookie: <REDACTED_EPHEMERAL_SESSION>", text)
        redacted = re.sub(r'(<meta name="csrf-token" content=")[^"]+("\s*/?>)', r"\1<REDACTED_CSRF>\2", redacted)
        redacted = re.sub(r'(<input name="_csrf_token"[^>]*value=")[^"]+("[^>]*>)', r"\1<REDACTED_CSRF>\2", redacted)
        lines = [line.rstrip() for line in redacted.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
        while lines and lines[-1] == "":
            lines.pop()
        redacted = "\n".join(lines) + ("\n" if lines else "")
        payload = redacted.encode("utf-8")
        if payload != original:
            path.write_bytes(payload)
        rel = str(path.relative_to(ROOT))
        prior = existing.get(rel)
        if payload != original or prior:
            records.append({"path": rel, "original_sha256": prior["original_sha256"] if prior else sha(original), "redacted_sha256": sha(payload), "redaction": "ephemeral session cookie/CSRF redaction plus deterministic line-ending/trailing-space normalization"})
    index = {"schema_version": "legendary-e03-redactions/v1", "assignment_id": "E03", "secret_values_retained": False, "file_count": len(records), "files": records}
    (ROOT / "redaction-index.json").write_text(json.dumps(index, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"E03 capture sanitization PASS files={len(records)}")


if __name__ == "__main__":
    main()
