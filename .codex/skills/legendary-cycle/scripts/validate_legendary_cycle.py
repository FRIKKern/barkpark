#!/usr/bin/env python3
"""Validate the machine-checkable Barkpark Legendary Cycle preflight contract."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


EPIC_VALIDATOR = Path(__file__).parents[2] / "epic-cycle" / "scripts" / "validate_epic_cycle.py"
SPEC = importlib.util.spec_from_file_location("legendary_cycle_epic_validator", EPIC_VALIDATOR)
EPIC = importlib.util.module_from_spec(SPEC)
if SPEC.loader is None:
    raise RuntimeError(f"cannot load Epic Cycle validator from {EPIC_VALIDATOR}")
SPEC.loader.exec_module(EPIC)

PHASE_HEADINGS = {
    "strategize": ("user wish", "strategic direction", "scale profile", "agent fleet", "survey"),
    "digest": (
        "user wish",
        "strategic direction",
        "scale profile",
        "agent fleet",
        "survey digest",
        "verification plan",
    ),
    "experiment": (
        "user wish",
        "strategic direction",
        "scale profile",
        "agent fleet",
        "survey digest",
        "verification plan",
        "experiment plan",
    ),
    "decide": (
        "user wish",
        "strategic direction",
        "scale profile",
        "agent fleet",
        "survey digest",
        "verification plan",
        "experiment verdict",
        "decisions",
    ),
    "build": (
        "user wish",
        "strategic direction",
        "scale profile",
        "agent fleet",
        "survey digest",
        "verification plan",
        "experiment verdict",
        "decisions",
        "shard manifest",
    ),
    "review": (
        "user wish",
        "strategic direction",
        "scale profile",
        "agent fleet",
        "survey digest",
        "verification plan",
        "experiment verdict",
        "decisions",
        "shard manifest",
    ),
}

FLEET_SPECS = {
    "survey": ("epic-surveyor", 60),
    "verify": ("epic-verifier", 30),
    "experiment": ("legendary-experimenter", 15),
    "build": ("legendary-builder", 15),
    "review": ("code-reviewer", 15),
}

REQUIRED_COMPLETIONS = {
    "strategize": (),
    "digest": ("survey",),
    "experiment": ("survey", "verify"),
    "decide": ("survey", "verify", "experiment"),
    "build": ("survey", "verify", "experiment"),
    "review": ("survey", "verify", "experiment", "build"),
}

EPIC.PHASE_HEADINGS = PHASE_HEADINGS
EPIC.FLEET_SPECS = FLEET_SPECS
EPIC.REQUIRED_COMPLETIONS = REQUIRED_COMPLETIONS

CLAIM_TTL_SECONDS = EPIC.CLAIM_TTL_SECONDS


def _scale_profile(paper: dict[str, Any]) -> dict[str, Any] | None:
    for block in EPIC.paper_blocks(paper):
        profile = block.get("scale_profile") if isinstance(block, dict) else None
        if isinstance(profile, dict):
            return profile
    return None


def validate_scale(paper: dict[str, Any]) -> list[str]:
    profile = _scale_profile(paper)
    if profile is None:
        return ["paper has no structured Scale profile record"]

    errors: list[str] = []
    unit_count = profile.get("unit_count")
    capacity = profile.get("proven_batch_capacity")
    planned = profile.get("planned_build_assignments")
    if not EPIC.nonempty_string(profile.get("unit_definition")):
        errors.append("scale profile has no unit_definition")
    if not isinstance(unit_count, int) or isinstance(unit_count, bool) or unit_count < 0:
        errors.append("scale profile unit_count is not a non-negative integer")
    if not EPIC.nonempty_string(profile.get("inventory_evidence")):
        errors.append("scale profile has no inventory_evidence")
    if profile.get("minimum_multiplier") != 5:
        errors.append("scale profile minimum_multiplier is not 5")
    width = profile.get("concurrency_width")
    if not isinstance(width, int) or isinstance(width, bool) or width < 1:
        errors.append("scale profile concurrency_width is invalid")
    if profile.get("build_formula") != "max(15, ceil(unit_count / proven_batch_capacity))":
        errors.append("scale profile build_formula is not canonical")
    surfaces = profile.get("target_surfaces")
    if not isinstance(surfaces, list) or not surfaces or not all(EPIC.nonempty_string(item) for item in surfaces):
        errors.append("scale profile target_surfaces is empty or invalid")
    if capacity is not None and (not isinstance(capacity, int) or isinstance(capacity, bool) or capacity < 1):
        errors.append("scale profile proven_batch_capacity is invalid")
    if capacity is not None and isinstance(unit_count, int) and not isinstance(unit_count, bool) and unit_count >= 0:
        expected = max(15, (unit_count + capacity - 1) // capacity)
        if planned != expected:
            errors.append(f"scale profile planned_build_assignments is not evaluated formula result {expected}")
    elif not isinstance(planned, int) or isinstance(planned, bool) or planned < 15:
        errors.append("scale profile planned_build_assignments is below 15 or invalid")
    return errors


def validate_fleet(paper: dict[str, Any], phase: str, require_debrief: bool) -> list[str]:
    fleet = next(
        (
            block.get("fleet")
            for block in EPIC.paper_blocks(paper)
            if isinstance(block, dict) and isinstance(block.get("fleet"), dict)
        ),
        None,
    )
    if fleet is None:
        return ["paper has no structured Agent fleet record"]

    profile = _scale_profile(paper) or {}
    profile_build_planned = profile.get("planned_build_assignments")
    errors: list[str] = []
    required = set(REQUIRED_COMPLETIONS[phase])
    if phase == "review" and require_debrief:
        required.add("review")

    for fleet_phase, (agent_type, minimum) in FLEET_SPECS.items():
        record = fleet.get(fleet_phase)
        if not isinstance(record, dict):
            errors.append(f"fleet has no {fleet_phase} record")
            continue
        planned = record.get("planned")
        if fleet_phase == "build":
            if not isinstance(planned, int) or planned < minimum:
                errors.append(f"fleet build planned count is below minimum {minimum} or invalid")
            if isinstance(profile_build_planned, int) and planned != profile_build_planned:
                errors.append("fleet build planned count does not match Scale profile")
        elif planned != minimum:
            errors.append(f"fleet {fleet_phase} planned count is not {minimum}")
        if record.get("agent_type") != agent_type:
            errors.append(f"fleet {fleet_phase} agent_type is not {agent_type}")

        started = record.get("started")
        failed = record.get("failed")
        if not isinstance(started, int) or started < 0:
            errors.append(f"fleet {fleet_phase} started count is invalid")
        if not isinstance(failed, int) or failed < 0:
            errors.append(f"fleet {fleet_phase} failed count is invalid")
        assignments = record.get("assignments")
        if not isinstance(assignments, list):
            errors.append(f"fleet {fleet_phase} assignments is not a list")
            assignments = []
        valid = [
            assignment
            for assignment in assignments
            if isinstance(assignment, dict)
            and EPIC.nonempty_string(assignment.get("id"))
            and assignment.get("agent_type") == agent_type
            and assignment.get("status") == "completed"
            and EPIC.nonempty_string(assignment.get("evidence"))
        ]
        if len({assignment["id"] for assignment in valid}) != len(valid):
            errors.append(f"fleet {fleet_phase} contains duplicate assignment ids")
        if record.get("completed") != len(valid):
            errors.append(f"fleet {fleet_phase} completed count does not match typed evidence")
        if isinstance(started, int) and started < len(valid):
            errors.append(f"fleet {fleet_phase} started count is below completed count")
        target = planned if isinstance(planned, int) and planned >= 0 else minimum
        if record.get("missing") != max(0, target - len(valid)):
            errors.append(f"fleet {fleet_phase} missing count is inconsistent")
        if fleet_phase in {"experiment"} and len(valid) > minimum and (len(valid) - minimum) % 3:
            errors.append("fleet experiment contains an incomplete additional wave")
        if fleet_phase == "review" and len(valid) > minimum and len(valid) % minimum:
            errors.append("fleet review contains an incomplete repeated review fleet")
        if fleet_phase in {"survey", "verify"} and len(valid) > minimum:
            errors.append(f"fleet {fleet_phase} exceeds its exact {minimum}-assignment contract")
        if fleet_phase == "build" and len(valid) > target:
            errors.append("fleet build exceeds its numerically planned assignment count")
        if fleet_phase in required and len(valid) < target:
            errors.append(f"fleet {fleet_phase} requires {target} completed typed assignments before {phase}")
    return errors


EPIC.validate_fleet = validate_fleet


def validate(args: Any) -> list[str]:
    errors = EPIC.validate(args)
    paper = EPIC.paper_doc(EPIC.load_json(args.paper_json)) if args.paper_json else EPIC.paper_doc(
        EPIC.command_json("bp", "doc", "get", "paper", args.paper, "-o", "json")
    )
    errors.extend(validate_scale(paper))
    return errors


def parser():
    return EPIC.parser()


def main() -> int:
    args = parser().parse_args()
    try:
        errors = validate(args)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"FAIL: could not load preflight evidence: {error}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: Legendary Cycle scale, fleet, Task, Paper, and PR evidence satisfy the preflight contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
