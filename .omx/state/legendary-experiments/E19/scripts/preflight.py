#!/usr/bin/env python3
"""Bounded, secret-free E19 deployment capability probe."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from common import CANDIDATE_ID, ROOT, capsules, experiment_root, fixtures, physical_hash, write_json


PINNED = {
    "E03/fixture-manifest.json": "0ab24d0a38f9d8db97073accaea37f02786d9c47f7dac3471e858907d5c308df",
    "E03/thresholds.json": "4117e563cb8d261b3256823fc90f16fb0e3d57a51fa84ab8b0a609d3684ecd6b",
    "E16/result.json": "b02c3a5e4ef7abe3bdef7eb2a97c536fe8b0fafb0b54ab013beb1136964e62c6",
}

REQUIRED_RUNTIME_CONTROLS = (
    "E19_ISOLATED_BASE_URL",
    "E19_DEPLOY_COMMAND",
    "E19_TEARDOWN_COMMAND",
    "E19_EXPIRY_MINUTES",
    "E19_STUDIO_SESSION_SECRET",
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, default=experiment_root("round-06-plan") / "assignments.json")
    parser.add_argument("--fixtures", type=Path, default=experiment_root("E03") / "fixture-manifest.json")
    parser.add_argument("--candidate", type=Path, default=experiment_root("E16") / "result.json")
    args = parser.parse_args()
    expected_paths = {
        "plan": experiment_root("round-06-plan") / "assignments.json",
        "fixtures": experiment_root("E03") / "fixture-manifest.json",
        "candidate": experiment_root("E16") / "result.json",
    }
    supplied_paths = {"plan": args.plan, "fixtures": args.fixtures, "candidate": args.candidate}
    if any(path.resolve() != expected_paths[name].resolve() for name, path in supplied_paths.items()):
        raise SystemExit("E19 PREFLIGHT FAIL: only canonical frozen inputs are accepted")

    observed = {}
    for relative, expected in PINNED.items():
        actual = physical_hash(experiment_root(relative.split("/", 1)[0]) / relative.split("/", 1)[1])
        observed[relative] = {"expected_sha256": expected, "actual_sha256": actual, "matches": actual == expected}

    e16 = json.loads((experiment_root("E16") / "result.json").read_text())
    candidate_digest = e16["evidence"]["capsules_sha256"]
    capsule_path = experiment_root("E16") / "output" / "capsules.jsonl"
    input_ok = (
        all(row["matches"] for row in observed.values())
        and e16["candidate_id"] == CANDIDATE_ID
        and physical_hash(capsule_path) == candidate_digest
        and len(fixtures()) == len(capsules()) == 36
    )
    controls = {name: bool(os.environ.get(name)) for name in REQUIRED_RUNTIME_CONTROLS}
    deployment_authorized = input_ok and all(controls.values())

    write_json(ROOT / "preflight.json", {
        "schema_version": "legendary-e19-preflight/v1",
        "assignment_id": "E19",
        "candidate_id": CANDIDATE_ID,
        "candidate_digest": candidate_digest,
        "bounded_probe": {
            "input_hashes": observed,
            "fixture_count": 36,
            "candidate_capsule_count": 36,
            "runtime_control_presence": controls,
            "secrets_persisted": False,
            "credential_values_observed": False,
            "network_requests_made": 0,
            "external_commands_executed": 0,
            "production_targets_contacted": 0,
        },
        "input_gate_passed": input_ok,
        "deployment_authorized": deployment_authorized,
        "verdict": "READY" if deployment_authorized else "BLOCKED",
        "stop_reason": None if deployment_authorized else "ISOLATION_EXPIRY_TEARDOWN_OR_AUTH_BROWSER_CONTROL_UNAVAILABLE",
    })
    print(f"E19 PREFLIGHT {'READY' if deployment_authorized else 'BLOCKED'} deployment_authorized={str(deployment_authorized).lower()}")


if __name__ == "__main__":
    main()
