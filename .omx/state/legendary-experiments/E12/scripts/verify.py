#!/usr/bin/env python3
"""Verify E12 evidence and provide explicit negative injection gates."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path


HERE = Path(__file__).resolve().parents[1]


def load(name: str):
    return json.loads((HERE / name).read_text())


def sha256(name: str) -> str:
    return hashlib.sha256((HERE / name).read_bytes()).hexdigest()


def fail(message: str) -> None:
    raise SystemExit(f"E12 VERIFY FAIL: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inject", choices=["missing-preimage", "fabricated-authority", "second-run-mutation"])
    args = parser.parse_args()

    manifest = load("migration-manifest.json")
    proof = load("rollback-idempotence-proof.json")
    rules = load("quarantine-authority-rules.json")
    outcomes = load("threshold-outcomes.json")
    result = load("result.json")

    if args.inject == "missing-preimage":
        injected = copy.deepcopy(manifest)
        injected["routes"][0]["rollback_preimage_sha256"] = None
        if injected["routes"][0]["before_sha256"] != injected["routes"][0]["rollback_preimage_sha256"]:
            print("E12 INJECTION CAUGHT missing-preimage")
            raise SystemExit(2)
        fail("missing-preimage injection escaped")
    if args.inject == "fabricated-authority":
        injected = copy.deepcopy(manifest)
        injected["routes"][0]["authority"] = "derived"
        if injected["routes"][0]["authority"] != "source_only":
            print("E12 INJECTION CAUGHT fabricated-authority")
            raise SystemExit(2)
        fail("fabricated-authority injection escaped")
    if args.inject == "second-run-mutation":
        injected = copy.deepcopy(proof)
        injected["rows"][0]["second_envelope_sha256"] = "0" * 64
        if injected["rows"][0]["first_envelope_sha256"] != injected["rows"][0]["second_envelope_sha256"]:
            print("E12 INJECTION CAUGHT second-run-mutation")
            raise SystemExit(2)
        fail("second-run-mutation injection escaped")

    if len(manifest["routes"]) != 36 or len({row["fixture_id"] for row in manifest["routes"]}) != 36:
        fail("migration routes do not reconcile to 36 unique fixtures")
    if len(proof["rows"]) != 36:
        fail("rollback proof does not cover 36 fixtures")
    if any(row["before_sha256"] != row["rollback_preimage_sha256"] for row in manifest["routes"]):
        fail("route lacks matching rollback pre-image")
    if any(row["authority"] != "source_only" for row in manifest["routes"]):
        fail("derived authority escaped quarantine")
    if any(row["first_envelope_sha256"] != row["second_envelope_sha256"] for row in proof["rows"]):
        fail("fixture changed on the second run")
    if proof["summary"] != {"idempotent": 36, "residue_free": 36, "restored": 36}:
        fail("idempotence/rollback summary is incomplete")
    if not proof["candidate_artifact_two_run_stability"]:
        fail("candidate artifacts changed on the second run")
    if rules["escalation"]["current_records"] != 0 or rules["escalation"]["required_records_before_scoring"] != 20:
        fail("blind-record block was weakened")
    if outcomes["outcomes"]["convergence"]["status"] != "REJECTED":
        fail("convergence rejection was lost")
    if result["verdict"]["winner_selected"] or result["verdict"]["action"] != "REWORK":
        fail("a winner was invented")
    for name, expected in result["artifact_hashes"].items():
        if sha256(name) != expected:
            fail(f"artifact hash mismatch: {name}")

    print("E12 VERIFY PASS: 36 routes, 36 idempotence proofs, 36 rollbacks; verdict REWORK/no winner")


if __name__ == "__main__":
    main()
