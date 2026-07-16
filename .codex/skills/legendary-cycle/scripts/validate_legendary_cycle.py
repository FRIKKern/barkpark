#!/usr/bin/env python3
"""Validate the machine-checkable Barkpark Legendary Cycle preflight contract."""

from __future__ import annotations

import importlib.util
import json
import re
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

FLEET_EFFORTS = {
    "survey": "medium",
    "verify": "medium",
    "experiment": "medium",
    "build": "medium",
    "review": "high",
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
EPIC.FLEET_EFFORTS = FLEET_EFFORTS
EPIC.REQUIRED_COMPLETIONS = REQUIRED_COMPLETIONS
EPIC.CYCLE_PHASE = "legendary"

CLAIM_TTL_SECONDS = EPIC.CLAIM_TTL_SECONDS
EXPERIMENT_ROUNDS = ("baseline", "diverge", "attack", "converge", "pilot")


def _scale_profile(paper: dict[str, Any]) -> dict[str, Any] | None:
    for block in EPIC.paper_blocks(paper):
        profile = block.get("scale_profile") if isinstance(block, dict) else None
        if isinstance(profile, dict):
            return profile
    return None


def _cycle_ledger_block(paper: dict[str, Any]) -> dict[str, Any] | None:
    for block in EPIC.paper_blocks(paper):
        ledger = block.get("cycle_ledger") if isinstance(block, dict) else None
        if isinstance(ledger, dict):
            return block
    return None


def _cycle_ledger(paper: dict[str, Any]) -> dict[str, Any] | None:
    block = _cycle_ledger_block(paper)
    return block.get("cycle_ledger") if block else None


def _paper_fleet(paper: dict[str, Any]) -> dict[str, Any] | None:
    for block in EPIC.paper_blocks(paper):
        fleet = block.get("fleet") if isinstance(block, dict) else None
        if isinstance(fleet, dict):
            return fleet
    return None


def _live_cycle_projection(
    args: Any, paper_ledger: dict[str, Any]
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    if getattr(args, "cycle_json", None):
        payload = EPIC.load_json(args.cycle_json)
    else:
        scope = paper_ledger.get("scope")
        if not isinstance(scope, dict):
            return None, None
        epic_id = scope.get("epic_id")
        wave_id = scope.get("wave_id")
        if not EPIC.nonempty_string(epic_id) or not EPIC.nonempty_string(wave_id):
            return None, None
        workspace = getattr(args, "workspace", None)
        project = getattr(args, "project", None)
        if not EPIC.nonempty_string(workspace) or not EPIC.nonempty_string(project):
            return None, None
        payload = EPIC.command_json(
            "bp", "--workspace", workspace, "--project", project,
            "cycle", "show", epic_id, wave_id, "-o", "json"
        )
    ledger = payload.get("cycle_ledger") if isinstance(payload, dict) else None
    fleet = payload.get("fleet") if isinstance(payload, dict) else None
    return (
        ledger if isinstance(ledger, dict) else None,
        fleet if isinstance(fleet, dict) else None,
    )


def validate_cycle_ledger(
    paper: dict[str, Any],
    phase: str,
    live_ledger: dict[str, Any] | None,
    live_fleet: dict[str, Any] | None,
    require_debrief: bool,
) -> list[str]:
    """Validate the reader-visible projection of Barkpark.CycleFleet."""
    ledger = _cycle_ledger(paper)
    if ledger is None:
        return ["paper has no structured CycleFleet ledger projection"]

    errors: list[str] = []
    block = _cycle_ledger_block(paper) or {}
    profile = _scale_profile(paper) or {}
    paper_fleet = _paper_fleet(paper)
    if ledger.get("profile") != "legendary":
        errors.append("cycle ledger profile is not legendary")
    for field in ("inventory_digest", "plan_digest", "reconciliation_digest"):
        value = ledger.get(field)
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
            errors.append(f"cycle ledger {field} is not a lowercase SHA-256 digest")

    inventory_count = ledger.get("inventory_count")
    if inventory_count != profile.get("unit_count"):
        errors.append("cycle ledger inventory_count does not match Scale profile")
    if ledger.get("planned_builders") != profile.get("planned_build_assignments"):
        errors.append("cycle ledger planned_builders does not match Scale profile")

    visible = " ".join(EPIC.strings(block.get("content"))).casefold()
    visible_fragments = (
        "legendary cyclefleet",
        str(ledger.get("wave_revision", "")).casefold(),
        f"{ledger.get('inventory_count')} inventoried",
        f"{ledger.get('assigned_count')} assigned",
        f"{ledger.get('shipped_count')} shipped",
        f"{ledger.get('stalled_count')} stalled",
        f"{ledger.get('excluded_count')} excluded",
        f"exact reconciliation {str(ledger.get('exact')).lower()}",
    )
    if not visible or not all(fragment and fragment in visible for fragment in visible_fragments):
        errors.append("cycle ledger callout has no complete reader-visible reconciliation summary")

    if live_ledger is None:
        errors.append("could not resolve the live CycleFleet authority for this Paper projection")
    elif ledger != live_ledger:
        errors.append("paper CycleFleet projection does not exactly match the live ledger authority")

    if live_ledger is not None:
        live_scale = live_ledger.get("scale_contract")
        live_capacity = live_ledger.get("capacity")
        if not isinstance(live_scale, dict) or not isinstance(live_capacity, dict):
            errors.append("live CycleFleet projection has no complete Scale contract and capacity")
        else:
            expected_profile = dict(live_scale)
            capacity = live_capacity.get("proven_batch_capacity")
            if capacity is not None:
                expected_profile["proven_batch_capacity"] = capacity
            expected_profile["planned_build_assignments"] = live_ledger.get("planned_builders")
            if profile != expected_profile:
                errors.append(
                    "paper Scale profile does not exactly match the live CycleFleet scale contract and capacity"
                )
            sealed = live_capacity.get("sealed")
            if not isinstance(sealed, bool):
                errors.append("live CycleFleet capacity sealed flag is not boolean")
            elif phase in {"decide", "build", "review"} and not sealed:
                errors.append(f"live CycleFleet capacity is not sealed before {phase}")
            if sealed:
                if live_capacity.get("failure_threshold") != live_scale.get("failure_threshold"):
                    errors.append(
                        "live CycleFleet capacity failure_threshold drifted from Scale contract"
                    )
                if live_capacity.get("quality_rubric") != live_scale.get("quality_rubric"):
                    errors.append(
                        "live CycleFleet capacity quality_rubric drifted from Scale contract"
                    )
            elif sealed is False:
                for field in (
                    "chosen_format",
                    "proven_batch_capacity",
                    "failure_rate",
                    "failure_threshold",
                    "golden_fixtures",
                    "quality_rubric",
                ):
                    if live_capacity.get(field) is not None:
                        errors.append(
                            f"live CycleFleet unsealed capacity {field} is not null"
                        )

    if live_fleet is None:
        errors.append("could not resolve the live CycleFleet fleet for this Paper projection")
    elif paper_fleet != live_fleet:
        errors.append("paper Agent fleet does not exactly match the live CycleFleet fleet")

    fleet_complete = ledger.get("fleet_complete")
    if not isinstance(fleet_complete, bool):
        errors.append("cycle ledger fleet_complete is not boolean")

    for field in (
        "assigned_count",
        "shipped_count",
        "stalled_count",
        "excluded_count",
    ):
        value = ledger.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            errors.append(f"cycle ledger {field} is invalid")

    for field in (
        "duplicate_assignment_unit_ids",
        "unknown_assignment_unit_ids",
        "unknown_outcome_unit_ids",
        "outcome_overlap_unit_ids",
        "outcome_ownership_violation_unit_ids",
        "unassigned_unit_ids",
        "unaccounted_unit_ids",
    ):
        value = ledger.get(field)
        if not isinstance(value, list) or not all(EPIC.nonempty_string(item) for item in value):
            errors.append(f"cycle ledger {field} is not a unit id list")

    if phase in {"build", "review"}:
        if ledger.get("duplicate_assignment_unit_ids"):
            errors.append("cycle ledger has multiply assigned units")
        if ledger.get("unknown_assignment_unit_ids"):
            errors.append("cycle ledger has assigned units outside the inventory")
        if ledger.get("unknown_outcome_unit_ids"):
            errors.append("cycle ledger has terminal outcomes outside the inventory")
        if ledger.get("outcome_ownership_violation_unit_ids"):
            errors.append("cycle ledger has terminal outcomes outside their assignment shard")
        if isinstance(inventory_count, int):
            assigned = ledger.get("assigned_count")
            if isinstance(assigned, int) and assigned != inventory_count:
                errors.append("cycle ledger does not reconcile inventoried = assigned")

    experiment = ledger.get("experiment")
    if not isinstance(experiment, dict):
        errors.append("cycle ledger has no experiment reconciliation")
    elif phase in {"decide", "build", "review"}:
        counts = experiment.get("round_counts")
        if not isinstance(counts, dict):
            errors.append("cycle ledger experiment round_counts is invalid")
        else:
            for round_name in EXPERIMENT_ROUNDS:
                count = counts.get(round_name, 0)
                if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                    errors.append(f"cycle ledger experiment round {round_name} count is invalid")
                elif count != 3:
                    errors.append(f"cycle ledger experiment round {round_name} does not have exactly 3 results")

    if phase == "review" and require_debrief:
        shipped = ledger.get("shipped_count")
        stalled = ledger.get("stalled_count")
        excluded = ledger.get("excluded_count")
        if all(isinstance(value, int) and not isinstance(value, bool) for value in (inventory_count, shipped, stalled, excluded)):
            if shipped + stalled + excluded != inventory_count:
                errors.append("cycle ledger does not reconcile inventoried = shipped + stalled + excluded")
        if ledger.get("outcome_overlap_unit_ids"):
            errors.append("cycle ledger has units in multiple terminal outcomes")
        if ledger.get("unaccounted_unit_ids"):
            errors.append("cycle ledger has unaccounted units")
        if ledger.get("exact") is not True:
            errors.append("cycle ledger exact flag is not true")
        if fleet_complete is not True:
            errors.append("cycle ledger fleet_complete flag is not true")
    return errors


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
    exclusions = profile.get("excluded_inventory")
    if not isinstance(exclusions, list):
        errors.append("scale profile excluded_inventory is not a list")
    elif not all(
        isinstance(item, dict)
        and EPIC.nonempty_string(item.get("unit_id"))
        and EPIC.nonempty_string(item.get("reason"))
        for item in exclusions
    ):
        errors.append("scale profile excluded_inventory entries are invalid")
    rubric = profile.get("quality_rubric")
    if not isinstance(rubric, dict) or not rubric:
        errors.append("scale profile quality_rubric is empty or invalid")
    threshold = profile.get("failure_threshold")
    if not isinstance(threshold, (int, float)) or isinstance(threshold, bool) or threshold < 0:
        errors.append("scale profile failure_threshold is invalid")
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
        if record.get("effort") != FLEET_EFFORTS[fleet_phase]:
            errors.append(
                f"fleet {fleet_phase} effort is not {FLEET_EFFORTS[fleet_phase]}"
            )

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
        if fleet_phase in {"survey", "verify", "experiment", "review"} and len(valid) > minimum:
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
    paper_ledger = _cycle_ledger(paper)
    live_ledger, live_fleet = (
        _live_cycle_projection(args, paper_ledger) if paper_ledger else (None, None)
    )
    errors.extend(
        validate_cycle_ledger(
            paper,
            args.phase,
            live_ledger,
            live_fleet,
            args.require_debrief,
        )
    )
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
    print(
        "PASS: Legendary Cycle scale, fleet ledger, Task, Paper, and PR evidence satisfy the preflight contract"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
