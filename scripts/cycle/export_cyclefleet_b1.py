#!/usr/bin/env python3
"""Export a scope-fenced B1 benchmark from an exact live Barkpark CycleFleet."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PHASES = ("survey", "verify", "experiment", "build", "review")
HEX64 = set("0123456789abcdef")


class FenceError(ValueError):
    pass


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise FenceError(message)


def require_digest(value: Any, label: str) -> str:
    require(isinstance(value, str) and len(value) == 64 and set(value) <= HEX64, f"{label} must be a lowercase SHA-256 digest")
    return value


def validate_benchmark(ledger: Any, expected: dict[str, str] | None = None) -> None:
    require(isinstance(ledger, dict), "B1 ledger must be an object")
    require(ledger.get("format") == "barkpark-epic-benchmark-v1", "B1 ledger format mismatch")
    experiment = ledger.get("experiment")
    require(isinstance(experiment, dict), "B1 experiment must be an object")
    manifest = ledger.get("manifest")
    attempts = ledger.get("attempts")
    summary = ledger.get("summary")
    require(isinstance(manifest, dict), "B1 manifest must be an object")
    require(isinstance(attempts, list), "B1 attempts must be an array")
    require(isinstance(summary, dict), "B1 summary must be an object")
    require_digest(ledger.get("manifest_digest"), "manifest_digest")
    require_digest(ledger.get("attempts_digest"), "attempts_digest")
    require_digest(ledger.get("summary_digest"), "summary_digest")
    require_digest(ledger.get("ledger_digest"), "ledger_digest")
    require(ledger["manifest_digest"] == digest(manifest), "B1 manifest_digest mismatch")
    require(ledger["attempts_digest"] == digest(attempts), "B1 attempts_digest mismatch")
    require(ledger["summary_digest"] == digest(summary), "B1 summary_digest mismatch")
    require(ledger["ledger_digest"] == digest({key: value for key, value in ledger.items() if key != "ledger_digest"}), "B1 ledger_digest mismatch")

    seen: set[str] = set()
    for index, attempt in enumerate(attempts):
        require(isinstance(attempt, dict), f"B1 attempt {index} must be an object")
        attempt_id = attempt.get("attempt_id")
        require(isinstance(attempt_id, str) and attempt_id and attempt_id not in seen, f"B1 attempt {index} has invalid or duplicate attempt_id")
        seen.add(attempt_id)
        require_digest(attempt.get("attempt_digest"), f"attempt {attempt_id} digest")
        require(attempt["attempt_digest"] == digest({key: value for key, value in attempt.items() if key != "attempt_digest"}), f"B1 attempt {attempt_id} digest mismatch")

    if expected is not None:
        experiment_keys = {"workspace_id", "epic_id", "wave_id", "experiment_id", "phase", "protocol_version"}
        require(set(experiment) == experiment_keys, "B1 experiment schema mismatch")
        for key in ("epic_id", "workspace_id", "wave_id"):
            require(experiment.get(key) == expected[key], f"B1 experiment {key} mismatch")
        receipt = manifest.get("cycle_scope_fence")
        receipt_keys = {
            "version", "workspace_id", "project_id", "epic_id", "wave_id", "wave_revision",
            "inventory_digest", "plan_digest", "reconciliation_digest", "fleet_digest", "receipt_digest",
        }
        require(isinstance(receipt, dict) and set(receipt) == receipt_keys, "B1 cycle_scope_fence schema mismatch")
        require(receipt["version"] == "b1-scope-fence-v1", "B1 cycle_scope_fence version mismatch")
        for key in ("workspace_id", "project_id", "epic_id", "wave_id", "wave_revision", "inventory_digest", "plan_digest"):
            require(receipt[key] == expected[key], f"B1 cycle_scope_fence {key} mismatch")
        for key in ("reconciliation_digest", "fleet_digest", "receipt_digest"):
            require_digest(receipt[key], f"B1 cycle_scope_fence {key}")
        require(receipt["receipt_digest"] == digest({key: value for key, value in receipt.items() if key != "receipt_digest"}), "B1 cycle_scope_fence receipt_digest mismatch")
        require(manifest.get("fleet_contract") == {"version": 1, "paper_fleet_digest": receipt["fleet_digest"]}, "B1 fleet_contract mismatch")
        for attempt in attempts:
            provenance = attempt.get("provenance")
            require(isinstance(provenance, dict), f"B1 attempt {attempt['attempt_id']} provenance missing")
            require(provenance.get("wave_revision") == expected["wave_revision"], f"B1 attempt {attempt['attempt_id']} provenance revision mismatch")
            require(provenance.get("scope_receipt_digest") == receipt["receipt_digest"], f"B1 attempt {attempt['attempt_id']} scope receipt mismatch")


def unwrap_cycle(value: Any) -> dict[str, Any]:
    if isinstance(value, dict) and isinstance(value.get("data"), dict):
        value = value["data"]
    require(isinstance(value, dict), "bp cycle show response must be an object")
    return value


def validate_live(cycle: dict[str, Any], expected: dict[str, str], selectors: dict[str, str]) -> None:
    authority = cycle.get("authority")
    ledger = cycle.get("cycle_ledger")
    fleet = cycle.get("fleet")
    require(isinstance(authority, dict), "live Cycle authority missing")
    require(isinstance(ledger, dict), "live cycle_ledger missing")
    require(isinstance(fleet, dict), "live fleet missing")
    require(authority.get("kind") == "barkpark_cycle_fleet", "live authority kind mismatch")
    require(ledger.get("profile") == "legendary", "live cycle_ledger profile mismatch")

    for key in ("workspace_id", "project_id", "epic_id", "wave_id", "wave_revision"):
        require(authority.get(key) == expected[key], f"live authority {key} mismatch")

    connection = authority.get("connection") or {}
    workspace = connection.get("workspace") or {}
    project = connection.get("project") or {}
    require(workspace.get("id") == expected["workspace_id"], "live connection workspace_id mismatch")
    require(project.get("id") == expected["project_id"], "live connection project_id mismatch")
    require(workspace.get("slug") == selectors["workspace"], "live connection workspace selector mismatch")
    require(project.get("slug") == selectors["project"], "live connection project selector mismatch")

    scope = ledger.get("scope")
    require(isinstance(scope, dict), "live cycle_ledger scope missing")
    for key in ("workspace_id", "project_id", "epic_id", "wave_id"):
        require(scope.get(key) == expected[key], f"live cycle_ledger {key} mismatch")
    require(ledger.get("wave_revision") == expected["wave_revision"], "live cycle_ledger wave_revision mismatch")
    require(ledger.get("inventory_digest") == expected["inventory_digest"], "live cycle_ledger inventory_digest mismatch")
    require(ledger.get("plan_digest") == expected["plan_digest"], "live cycle_ledger plan_digest mismatch")
    require_digest(ledger.get("reconciliation_digest"), "live reconciliation_digest")


def build_scope_receipt(cycle: dict[str, Any], expected: dict[str, str]) -> dict[str, Any]:
    receipt = {
        "version": "b1-scope-fence-v1",
        "workspace_id": expected["workspace_id"],
        "project_id": expected["project_id"],
        "epic_id": expected["epic_id"],
        "wave_id": expected["wave_id"],
        "wave_revision": expected["wave_revision"],
        "inventory_digest": expected["inventory_digest"],
        "plan_digest": expected["plan_digest"],
        "reconciliation_digest": cycle["cycle_ledger"]["reconciliation_digest"],
        "fleet_digest": digest(cycle["fleet"]),
    }
    receipt["receipt_digest"] = digest(receipt)
    return receipt


def validate_scope_receipt(receipt: Any, cycle: dict[str, Any], expected: dict[str, str]) -> None:
    keys = {
        "version", "workspace_id", "project_id", "epic_id", "wave_id", "wave_revision",
        "inventory_digest", "plan_digest", "reconciliation_digest", "fleet_digest", "receipt_digest",
    }
    require(isinstance(receipt, dict) and set(receipt) == keys, "generated cycle_scope_fence schema mismatch")
    require(receipt["version"] == "b1-scope-fence-v1", "generated cycle_scope_fence version mismatch")
    for key in ("workspace_id", "project_id", "epic_id", "wave_id", "wave_revision", "inventory_digest", "plan_digest"):
        require(receipt[key] == expected[key], f"generated cycle_scope_fence {key} mismatch")
    require(receipt["reconciliation_digest"] == cycle["cycle_ledger"]["reconciliation_digest"], "generated reconciliation_digest mismatch")
    require(receipt["fleet_digest"] == digest(cycle["fleet"]), "generated fleet_digest mismatch")
    require(receipt["receipt_digest"] == digest({key: value for key, value in receipt.items() if key != "receipt_digest"}), "generated scope receipt digest mismatch")


def generated_benchmark(cycle: dict[str, Any], expected: dict[str, str]) -> dict[str, Any]:
    attempts: list[dict[str, Any]] = []
    ordinal = 0
    fleet = cycle["fleet"]
    scope_receipt = build_scope_receipt(cycle, expected)
    validate_scope_receipt(scope_receipt, cycle, expected)
    for phase in PHASES:
        phase_data = fleet.get(phase)
        require(isinstance(phase_data, dict), f"live fleet phase {phase} missing")
        assignments = phase_data.get("assignments")
        require(isinstance(assignments, list), f"live fleet phase {phase} assignments missing")
        require(all(isinstance(item, dict) for item in assignments), f"live fleet phase {phase} assignment invalid")
        for assignment in sorted(assignments, key=lambda item: (item.get("id", ""), canonical(item))):
            require(isinstance(assignment.get("id"), str) and assignment["id"], f"live fleet phase {phase} assignment id invalid")
            require(isinstance(assignment.get("agent_type"), str) and assignment["agent_type"], f"live fleet phase {phase} assignment agent_type invalid")
            require(isinstance(assignment.get("evidence"), str) and assignment["evidence"], f"live fleet phase {phase} assignment evidence invalid")
            ordinal += 1
            attempt = {
                "attempt_id": f"cycle-{phase}-{assignment['id']}",
                "replaces_attempt_id": None,
                "ordinal": ordinal,
                "status": "completed",
                "treatment": "cyclefleet-reconciliation",
                "costs": {
                    "wall_seconds": {"state": "unsupported", "reason": "CycleFleet terminal receipt has no comparable wall-duration field"},
                    "provider_tokens": {"state": "unsupported", "reason": "CycleFleet terminal receipt has no provider-token field"},
                    "context_bytes": {"state": "missing", "reason": "CycleFleet terminal receipt has no context-byte field"},
                },
                "provenance": {
                    "source": "canonical live CycleFleet assignment and terminal-result projection",
                    "wave_revision": expected["wave_revision"],
                    "scope_receipt_digest": scope_receipt["receipt_digest"],
                },
                "payload": {
                    "fleet_assignment": {
                        "phase": phase,
                        "assignment_id": assignment["id"],
                        "agent_type": assignment["agent_type"],
                        "evidence": assignment["evidence"],
                        "model_reasoning_effort": "high" if phase in {"build", "review"} else "medium",
                    }
                },
            }
            attempt["attempt_digest"] = digest(attempt)
            attempts.append(attempt)

    outcomes = {status: 0 for status in ("completed", "failed", "timeout", "contaminated", "cancelled")}
    outcomes["completed"] = len(attempts)
    cost_states = {"observed": 0, "unsupported": len(attempts) * 2, "missing": len(attempts), "invalid": 0}
    summary = {
        "attempt_count": len(attempts),
        "outcomes": outcomes,
        "cost_states": cost_states,
        "treatments": {"cyclefleet-reconciliation": len(attempts)},
    }
    manifest = {
        "fleet_contract": {"version": 1, "paper_fleet_digest": digest(fleet)},
        "cycle_scope_fence": scope_receipt,
    }
    benchmark = {
        "format": "barkpark-epic-benchmark-v1",
        "experiment": {
            "workspace_id": expected["workspace_id"],
            "epic_id": expected["epic_id"],
            "wave_id": expected["wave_id"],
            "experiment_id": "cyclefleet-b1-scope-fenced",
            "phase": cycle["cycle_ledger"].get("profile"),
            "protocol_version": 1,
        },
        "manifest": manifest,
        "manifest_digest": digest(manifest),
        "attempts": attempts,
        "attempts_digest": digest(attempts),
        "summary": summary,
        "summary_digest": digest(summary),
    }
    benchmark["ledger_digest"] = digest(benchmark)
    validate_benchmark(benchmark, expected)
    validate_scope_receipt(benchmark["manifest"]["cycle_scope_fence"], cycle, expected)
    return benchmark


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
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


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--project", required=True)
    for name in ("workspace-id", "project-id", "epic-id", "wave-id", "wave-revision", "inventory-digest", "plan-digest"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--bp", default="bp")
    args = parser.parse_args(argv)
    for key, value in vars(args).items():
        if isinstance(value, str) and key != "bp":
            require(bool(value.strip()), f"{key} must not be blank")
    require_digest(args.inventory_digest, "inventory_digest")
    require_digest(args.plan_digest, "plan_digest")
    return args


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    expected = {
        "workspace_id": args.workspace_id,
        "project_id": args.project_id,
        "epic_id": args.epic_id,
        "wave_id": args.wave_id,
        "wave_revision": args.wave_revision,
        "inventory_digest": args.inventory_digest,
        "plan_digest": args.plan_digest,
    }
    selectors = {"workspace": args.workspace, "project": args.project}
    command = [args.bp, "-w", args.workspace, "-p", args.project, "--json", "cycle", "show", args.epic_id, args.wave_id]
    completed = subprocess.run(command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(completed.returncode == 0, f"bp cycle show failed with exit {completed.returncode}")
    try:
        cycle = unwrap_cycle(json.loads(completed.stdout))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FenceError(f"bp cycle show returned invalid JSON: {exc}") from exc
    validate_live(cycle, expected, selectors)
    benchmark = generated_benchmark(cycle, expected)
    payload = canonical(benchmark).encode("utf-8")
    decoded = json.loads(payload)
    validate_benchmark(decoded, expected)
    validate_scope_receipt(decoded["manifest"]["cycle_scope_fence"], cycle, expected)
    atomic_write(args.output, payload)
    return 0


def main() -> None:
    try:
        raise SystemExit(run(sys.argv[1:]))
    except (FenceError, OSError) as exc:
        print(f"b1-scope-fence: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
