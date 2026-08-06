#!/usr/bin/env python3
"""Run E05 twice and prove byte-identical candidate replay."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
E05 = HERE.parent


def run(script: str) -> None:
    subprocess.run([sys.executable, str(HERE / script)], cwd=E05, check=True)


def snapshot() -> tuple[str, dict[str, str]]:
    excluded = {"replay-proof.json"}
    files = {}
    for path in sorted(E05.rglob("*")):
        if path.is_file() and path.name not in excluded and "__pycache__" not in path.parts:
            files[str(path.relative_to(E05))] = hashlib.sha256(path.read_bytes()).hexdigest()
    payload = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest(), files


def main() -> int:
    run("test_core.py")
    run("build.py")
    run("verify.py")
    first_hash, first_files = snapshot()
    run("build.py")
    run("verify.py")
    second_hash, second_files = snapshot()
    if first_files != second_files:
        changed = sorted(set(first_files) | set(second_files))
        changed = [path for path in changed if first_files.get(path) != second_files.get(path)]
        raise SystemExit(f"E05 REPLAY FAIL changed={changed}")
    proof = {
        "schema_version": "legendary-restart-e05-replay-proof/v1",
        "runs": 2,
        "byte_identical": True,
        "first_sha256": first_hash,
        "second_sha256": second_hash,
        "file_count": len(first_files),
    }
    (E05 / "reports" / "replay-proof.json").write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")) + "\n")
    result = json.loads((E05 / "result.json").read_text())
    result["replay"] = proof
    (E05 / "result.json").write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"E05 REPLAY PASS files={len(first_files)} sha256={first_hash}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
