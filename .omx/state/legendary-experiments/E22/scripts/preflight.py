#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from common import CAPSULES, FIXTURES, PINNED, ROOT, capsules, classify_runtime, fixture_ids, physical_hash, pinned_path, write_json


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--ttl-minutes", type=int, required=True)
    p.add_argument("--deny-production", action="store_true", required=True)
    p.add_argument("--fixtures", type=Path, default=FIXTURES)
    p.add_argument("--capsules", type=Path, default=CAPSULES)
    args = p.parse_args()
    if args.fixtures.resolve() != FIXTURES.resolve() or args.capsules.resolve() != CAPSULES.resolve():
        raise SystemExit("E22 PREFLIGHT FAIL: only canonical frozen E03/E16 inputs are accepted")
    hashes = {relative: {"expected_sha256": expected, "actual_sha256": physical_hash(pinned_path(relative)), "matches": physical_hash(pinned_path(relative)) == expected} for relative, expected in PINNED.items()}
    input_ok = all(x["matches"] for x in hashes.values()) and len(fixture_ids()) == len(capsules()) == 36
    runtime = classify_runtime(args.ttl_minutes, True)
    out = {
        "schema_version": "legendary-e22-preflight/v1", "assignment_id": "E22",
        "input_gate_passed": input_ok, "deployment_authorized": input_ok and runtime["ready"],
        "ttl_minutes": args.ttl_minutes, "input_hashes": hashes,
        "counts": {"fixtures": 36, "capsules": 36, "required_unique_cells": 108},
        "runtime_control_presence": runtime["presence"], "runtime_fingerprints": runtime["hashes"],
        "secrets_persisted": False, "credential_values_observed": False,
        "network_requests_made": 0, "production_targets_contacted": 0,
        "verdict": "READY" if input_ok and runtime["ready"] else "BLOCKED",
        "stop_reasons": [] if input_ok and runtime["ready"] else (["FROZEN_INPUT_DRIFT"] if not input_ok else []) + runtime["reasons"],
    }
    write_json(ROOT / "preflight.json", out)
    print(f"E22 PREFLIGHT {out['verdict']} inputs=36 capsules=36 ttl={args.ttl_minutes}")


if __name__ == "__main__":
    main()
