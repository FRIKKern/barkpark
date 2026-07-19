#!/usr/bin/env python3
"""Build one canonical, fail-closed Legendary release-gate-v1 artifact."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / ".codex" / "skills" / "legendary-cycle" / "scripts" / "validate_legendary_cycle.py"
SPEC = importlib.util.spec_from_file_location("legendary_release_gate", VALIDATOR)
MODULE = importlib.util.module_from_spec(SPEC)
if SPEC.loader is None:
    raise RuntimeError(f"cannot load Legendary validator from {VALIDATOR}")
SPEC.loader.exec_module(MODULE)


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise MODULE.ReleaseGateError(f"{path} must contain a JSON object")
    return value


def canonical(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--stage", required=True, choices=("open", "activate"))
    value.add_argument("--evidence-json", required=True, type=Path)
    value.add_argument("--output", required=True, type=Path)
    return value


def run(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    artifact = MODULE.build_release_gate_bundle(args.stage, load_json(args.evidence_json))
    atomic_write(args.output, canonical(artifact))
    return 0


def main() -> None:
    try:
        raise SystemExit(run(sys.argv[1:]))
    except (MODULE.ReleaseGateError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"release-gate: {error}", file=sys.stderr)
        raise SystemExit(2) from error


if __name__ == "__main__":
    main()
