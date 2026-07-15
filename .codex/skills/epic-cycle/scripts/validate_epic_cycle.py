#!/usr/bin/env python3
"""Validate the machine-checkable Barkpark Epic Cycle preflight contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


PHASE_HEADINGS = {
    "strategize": ("user wish", "strategic direction", "agent fleet", "survey"),
    "digest": ("user wish", "strategic direction", "agent fleet", "survey digest", "verification plan"),
    "decide": ("user wish", "strategic direction", "agent fleet", "survey digest", "verification plan", "decisions"),
    "build": ("user wish", "strategic direction", "agent fleet", "survey digest", "verification plan", "decisions", "wave slice"),
    "review": ("user wish", "strategic direction", "agent fleet", "survey digest", "verification plan", "decisions", "wave slice"),
}

FLEET_SPECS = {
    "survey": ("epic-surveyor", 12),
    "verify": ("epic-verifier", 6),
    "build": ("epic-builder", 3),
    "review": ("code-reviewer", 3),
}

FLEET_EFFORTS = {
    "survey": "medium",
    "verify": "medium",
    "build": "high",
    "review": "high",
}

REQUIRED_COMPLETIONS = {
    "strategize": (),
    "digest": ("survey",),
    "decide": ("survey", "verify"),
    "build": ("survey", "verify"),
    "review": ("survey", "verify", "build"),
}

CLAIM_TTL_SECONDS = 2700
CYCLE_PHASE = "epic"

LEDGER_FORMAT = "barkpark-epic-benchmark-v1"
LEDGER_KEYS = {
    "format",
    "experiment",
    "manifest",
    "manifest_digest",
    "attempts",
    "attempts_digest",
    "summary",
    "summary_digest",
    "ledger_digest",
}
EXPERIMENT_KEYS = {
    "workspace_id",
    "epic_id",
    "wave_id",
    "experiment_id",
    "phase",
    "protocol_version",
}
ATTEMPT_KEYS = {
    "attempt_id",
    "replaces_attempt_id",
    "ordinal",
    "treatment",
    "status",
    "costs",
    "provenance",
    "payload",
    "attempt_digest",
}
FLEET_ASSIGNMENT_KEYS = {
    "phase",
    "assignment_id",
    "agent_type",
    "evidence",
    "model_reasoning_effort",
}
ATTEMPT_STATUSES = ("completed", "failed", "timeout", "contaminated", "cancelled")
COST_STATES = ("observed", "unsupported", "missing", "invalid")
SENSITIVE_EXACT = {
    "token",
    "access_token",
    "refresh_token",
    "auth_token",
    "id_token",
    "session_token",
    "api_key",
    "apikey",
    "secret",
    "client_secret",
    "webhook_secret",
    "secret_key",
    "password",
    "authorization",
    "cookie",
    "set_cookie",
    "private_key",
    "signing_key",
    "bearer",
    "credential",
    "credentials",
    "dsn",
    "database_url",
    "database_uri",
    "connection_string",
}
SENSITIVE_SUFFIXES = (
    "_access_token",
    "_refresh_token",
    "_auth_token",
    "_id_token",
    "_session_token",
    "_api_key",
    "_client_secret",
    "_webhook_secret",
    "_secret_key",
    "_secret",
    "_password",
    "_private_key",
    "_signing_key",
    "_credential",
    "_credentials",
    "_dsn",
    "_database_url",
    "_database_uri",
    "_connection_string",
)
CYCLEFLEET_PAPER_CUTOFF = datetime(2026, 7, 15, 0, 5, tzinfo=timezone.utc)


def command_json(*args: str) -> dict[str, Any]:
    result = subprocess.run(args, check=True, text=True, capture_output=True)
    return json.loads(result.stdout)


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def canonical_json(value: Any) -> str:
    """Mirror Barkpark.EpicFleet.CanonicalJSON for cross-runtime digests."""
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def load_canonical_ledger(path: Path) -> dict[str, Any]:
    raw = path.read_text(encoding="utf-8")

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-JSON numeric constant {value}")

    payload = json.loads(raw, parse_constant=reject_constant)
    if not isinstance(payload, dict):
        raise ValueError("top level is not an object")
    if raw != canonical_json(payload):
        raise ValueError("bytes are not the canonical B1 exporter encoding")
    return payload


def task_doc(payload: dict[str, Any]) -> dict[str, Any]:
    return payload.get("doc", payload)


def paper_doc(payload: dict[str, Any]) -> dict[str, Any]:
    """Accept CLI-unwrapped documents and raw API result envelopes."""
    result = payload.get("result")
    if isinstance(result, list):
        return result[0] if result else {}
    return result if isinstance(result, dict) else payload


def task_fields(doc: dict[str, Any]) -> dict[str, Any]:
    fields = dict(doc.get("content") or {})
    for key, value in doc.items():
        if key != "content" and key not in fields:
            fields[key] = value
    return fields


def strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        result: list[str] = []
        for child in value.values():
            result.extend(strings(child))
        return result
    if isinstance(value, list):
        result = []
        for child in value:
            result.extend(strings(child))
        return result
    return []


def has_label_value(labels: list[Any], prefix: str) -> bool:
    return any(isinstance(label, str) and label.startswith(prefix) and label[len(prefix):].strip() for label in labels)


def nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def integer(value: Any, minimum: int = 0) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def sensitive_key(key: str) -> bool:
    normalized = key.casefold().replace("-", "_")
    return normalized in SENSITIVE_EXACT or any(
        normalized.endswith(suffix) for suffix in SENSITIVE_SUFFIXES
    )


def sanitized(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: "[REDACTED]" if sensitive_key(key) else sanitized(child)
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [sanitized(child) for child in value]
    return value


def valid_costs(costs: Any) -> bool:
    if not isinstance(costs, dict) or not costs:
        return False
    for metric, envelope in costs.items():
        if not nonempty_string(metric) or not isinstance(envelope, dict):
            return False
        state = envelope.get("state")
        if state == "observed":
            value = envelope.get("value")
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                return False
        elif state in {"unsupported", "missing", "invalid"}:
            if not nonempty_string(envelope.get("reason")):
                return False
        else:
            return False
    return True


def benchmark_summary(attempts: list[dict[str, Any]]) -> dict[str, Any]:
    outcomes = {status: 0 for status in ATTEMPT_STATUSES}
    cost_states = {state: 0 for state in COST_STATES}
    treatments: dict[str, int] = {}
    for attempt in attempts:
        outcomes[attempt["status"]] += 1
        treatments[attempt["treatment"]] = treatments.get(attempt["treatment"], 0) + 1
        for metric in attempt["costs"].values():
            cost_states[metric["state"]] += 1
    return {
        "attempt_count": len(attempts),
        "outcomes": outcomes,
        "cost_states": cost_states,
        "treatments": treatments,
    }


def paper_fleet(paper: dict[str, Any]) -> dict[str, Any] | None:
    return next(
        (
            block.get("fleet")
            for block in paper_blocks(paper)
            if isinstance(block, dict) and isinstance(block.get("fleet"), dict)
        ),
        None,
    )


def validate_ledger(
    ledger: dict[str, Any],
    paper: dict[str, Any],
    epic_id: Any,
    paper_id: str,
) -> list[str]:
    """Validate B1 canonical truth and reconcile its terminal leaves to the Paper projection."""
    errors: list[str] = []
    if set(ledger) != LEDGER_KEYS:
        return ["fleet ledger has an invalid canonical document shape"]
    if ledger.get("format") != LEDGER_FORMAT:
        errors.append(f"fleet ledger format is not {LEDGER_FORMAT}")

    experiment = ledger.get("experiment")
    if not isinstance(experiment, dict) or set(experiment) != EXPERIMENT_KEYS:
        errors.append("fleet ledger experiment has an invalid shape")
        experiment = {}
    else:
        for field in ("workspace_id", "epic_id", "wave_id", "experiment_id"):
            if not nonempty_string(experiment.get(field)):
                errors.append(f"fleet ledger experiment {field} is empty or invalid")
        if experiment.get("epic_id") != epic_id:
            errors.append(
                f"fleet ledger epic scope is {experiment.get('epic_id')!r}, expected {epic_id!r}"
            )
        if experiment.get("wave_id") != paper_id:
            errors.append(
                f"fleet ledger wave scope is {experiment.get('wave_id')!r}, expected {paper_id!r}"
            )
        if experiment.get("phase") != CYCLE_PHASE:
            errors.append(
                f"fleet ledger cycle phase is {experiment.get('phase')!r}, expected {CYCLE_PHASE!r}"
            )
        if experiment.get("protocol_version") != 1:
            errors.append("fleet ledger protocol_version is not 1")

    manifest = ledger.get("manifest")
    if not isinstance(manifest, dict):
        errors.append("fleet ledger manifest is not an object")
        manifest = {}
    contract = manifest.get("fleet_contract")
    expected_contract_keys = {"version", "paper_fleet_digest"}
    if not isinstance(contract, dict) or set(contract) != expected_contract_keys:
        errors.append("fleet ledger manifest has no exact fleet_contract v1 scope")
    else:
        if contract.get("version") != 1:
            errors.append("fleet ledger fleet_contract version is not 1")
        projection = paper_fleet(paper)
        if projection is None:
            errors.append("fleet ledger cannot reconcile a missing Paper fleet")
        elif contract.get("paper_fleet_digest") != canonical_digest(projection):
            errors.append("fleet ledger Paper fleet digest is stale")

    attempts = ledger.get("attempts")
    if not isinstance(attempts, list):
        errors.append("fleet ledger attempts is not a list")
        attempts = []

    attempts_valid = True
    attempt_ids: set[str] = set()
    projections: dict[str, dict[str, Any]] = {}
    for index, attempt in enumerate(attempts):
        prefix = f"fleet ledger attempt {index + 1}"
        if not isinstance(attempt, dict) or set(attempt) != ATTEMPT_KEYS:
            errors.append(f"{prefix} has an invalid shape")
            attempts_valid = False
            continue
        attempt_id = attempt.get("attempt_id")
        replacement_id = attempt.get("replaces_attempt_id")
        if not nonempty_string(attempt_id):
            errors.append(f"{prefix} has an invalid attempt_id")
            attempts_valid = False
        elif attempt_id in attempt_ids:
            errors.append(f"fleet ledger contains duplicate attempt id {attempt_id!r}")
            attempts_valid = False
        else:
            attempt_ids.add(attempt_id)
        if replacement_id is not None and not nonempty_string(replacement_id):
            errors.append(f"{prefix} has an invalid replaces_attempt_id")
            attempts_valid = False
        if not integer(attempt.get("ordinal"), 1):
            errors.append(f"{prefix} has an invalid ordinal")
            attempts_valid = False
        if not nonempty_string(attempt.get("treatment")):
            errors.append(f"{prefix} has an invalid treatment")
            attempts_valid = False
        if attempt.get("status") not in ATTEMPT_STATUSES:
            errors.append(f"{prefix} has an invalid status")
            attempts_valid = False
        if not valid_costs(attempt.get("costs")):
            errors.append(f"{prefix} costs do not use exhaustive typed states")
            attempts_valid = False
        if not isinstance(attempt.get("provenance"), dict):
            errors.append(f"{prefix} provenance is not an object")
            attempts_valid = False
        payload = attempt.get("payload")
        if not isinstance(payload, dict):
            errors.append(f"{prefix} payload is not an object")
            attempts_valid = False
            continue
        assignment = payload.get("fleet_assignment")
        if not isinstance(assignment, dict) or set(assignment) != FLEET_ASSIGNMENT_KEYS:
            errors.append(f"{prefix} has no exact fleet_assignment projection")
            attempts_valid = False
            continue
        if assignment.get("phase") not in FLEET_SPECS:
            errors.append(f"{prefix} fleet_assignment phase is invalid")
            attempts_valid = False
        if not nonempty_string(assignment.get("assignment_id")):
            errors.append(f"{prefix} fleet_assignment assignment_id is invalid")
            attempts_valid = False
        phase_spec = FLEET_SPECS.get(assignment.get("phase"))
        if phase_spec and assignment.get("agent_type") != phase_spec[0]:
            errors.append(f"{prefix} fleet_assignment agent_type is invalid")
            attempts_valid = False
        if not nonempty_string(assignment.get("evidence")):
            errors.append(f"{prefix} fleet_assignment evidence is invalid")
            attempts_valid = False
        effort = assignment.get("model_reasoning_effort")
        if not nonempty_string(effort):
            errors.append(f"{prefix} fleet_assignment effort is invalid")
            attempts_valid = False
        effort_phase = assignment.get("phase")
        if effort_phase in {"build", "review"} and effort != "high":
            errors.append(f"{prefix} {effort_phase.title()} effort is not exactly high")
            attempts_valid = False
        if nonempty_string(attempt_id):
            projections[attempt_id] = assignment

        semantic = {key: value for key, value in attempt.items() if key != "attempt_digest"}
        if attempt.get("attempt_digest") != canonical_digest(semantic):
            errors.append(f"{prefix} digest does not match canonical attempt content")
            attempts_valid = False

    if attempts_valid:
        ordinals = [attempt["ordinal"] for attempt in attempts]
        if len(set(ordinals)) != len(ordinals):
            errors.append("fleet ledger attempt ordinals are not unique")
            attempts_valid = False
        if sorted(ordinals) != list(range(1, len(attempts) + 1)):
            errors.append("fleet ledger attempt ordinals are not contiguous from 1")
            attempts_valid = False
        if attempts != sorted(
            attempts, key=lambda attempt: (attempt["ordinal"], attempt["attempt_id"])
        ):
            errors.append("fleet ledger attempts are not in canonical order")
            attempts_valid = False

    if manifest != sanitized(manifest) or attempts != sanitized(attempts):
        errors.append("fleet ledger contains unredacted secret fields")

    if ledger.get("manifest_digest") != canonical_digest(manifest):
        errors.append("fleet ledger manifest digest mismatch")
    if ledger.get("attempts_digest") != canonical_digest(attempts):
        errors.append("fleet ledger attempts digest mismatch")
    if attempts_valid:
        expected_summary = benchmark_summary(attempts)
        if ledger.get("summary") != expected_summary:
            errors.append("fleet ledger summary does not account for every attempt and cost state")
        if ledger.get("summary_digest") != canonical_digest(ledger.get("summary")):
            errors.append("fleet ledger summary digest mismatch")
    elif not isinstance(ledger.get("summary"), dict):
        errors.append("fleet ledger summary is not an object")
    base = {key: value for key, value in ledger.items() if key != "ledger_digest"}
    if ledger.get("ledger_digest") != canonical_digest(base):
        errors.append("fleet ledger digest mismatch")

    if not attempts_valid:
        return errors

    attempts_by_id = {attempt["attempt_id"]: attempt for attempt in attempts}
    replaced_by: dict[str, str] = {}
    for attempt in attempts:
        replacement_id = attempt["replaces_attempt_id"]
        if replacement_id is None:
            continue
        predecessor = attempts_by_id.get(replacement_id)
        if predecessor is None or predecessor["ordinal"] >= attempt["ordinal"]:
            errors.append(f"fleet ledger replacement ancestry is invalid for {attempt['attempt_id']!r}")
            continue
        if replacement_id in replaced_by:
            errors.append(f"fleet ledger replacement ancestry forks at {replacement_id!r}")
        else:
            replaced_by[replacement_id] = attempt["attempt_id"]
        predecessor_assignment = projections[replacement_id]
        assignment = projections[attempt["attempt_id"]]
        stable_keys = ("phase", "assignment_id", "agent_type", "model_reasoning_effort")
        if any(predecessor_assignment[key] != assignment[key] for key in stable_keys):
            errors.append(f"fleet ledger replacement changes assignment identity for {attempt['attempt_id']!r}")

    attempts_by_assignment: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for attempt in attempts:
        assignment = projections[attempt["attempt_id"]]
        assignment_key = (assignment["phase"], assignment["assignment_id"])
        attempts_by_assignment.setdefault(assignment_key, []).append(attempt)
    for (fleet_phase, assignment_id), logical_attempts in attempts_by_assignment.items():
        if len(logical_attempts) == 1:
            continue
        logical_ids = {attempt["attempt_id"] for attempt in logical_attempts}
        roots = [attempt for attempt in logical_attempts if attempt["replaces_attempt_id"] is None]
        leaves = [attempt for attempt in logical_attempts if attempt["attempt_id"] not in replaced_by]
        links_stay_with_assignment = all(
            attempt["replaces_attempt_id"] is None
            or attempt["replaces_attempt_id"] in logical_ids
            for attempt in logical_attempts
        )
        if len(roots) != 1 or len(leaves) != 1 or not links_stay_with_assignment:
            errors.append(
                f"fleet ledger logical assignment {fleet_phase + '/' + assignment_id!r} attempts "
                "do not form one linear replacement chain with exactly one terminal leaf"
            )

    projection = paper_fleet(paper) or {}
    leaves = [attempt for attempt in attempts if attempt["attempt_id"] not in replaced_by]
    for fleet_phase in FLEET_SPECS:
        record = projection.get(fleet_phase)
        if not isinstance(record, dict):
            continue
        phase_attempts = [
            attempt
            for attempt in attempts
            if projections[attempt["attempt_id"]]["phase"] == fleet_phase
        ]
        terminal = [
            attempt
            for attempt in leaves
            if projections[attempt["attempt_id"]]["phase"] == fleet_phase
            and attempt["status"] == "completed"
        ]
        terminal_rows = [
            (
                projections[attempt["attempt_id"]]["assignment_id"],
                projections[attempt["attempt_id"]]["agent_type"],
                projections[attempt["attempt_id"]]["evidence"],
            )
            for attempt in terminal
        ]
        paper_rows = [
            (assignment.get("id"), assignment.get("agent_type"), assignment.get("evidence"))
            for assignment in record.get("assignments", [])
            if isinstance(assignment, dict)
            and assignment.get("status") == "completed"
            and nonempty_string(assignment.get("id"))
            and nonempty_string(assignment.get("agent_type"))
            and nonempty_string(assignment.get("evidence"))
        ]
        terminal_ids = [row[0] for row in terminal_rows]
        if len(set(terminal_ids)) != len(terminal_ids):
            errors.append(f"fleet ledger {fleet_phase} has duplicate terminal assignment ids")
        if sorted(terminal_rows) != sorted(paper_rows):
            errors.append(
                f"fleet ledger {fleet_phase} terminal completions do not match the Paper projection"
            )
        if record.get("completed") != len(terminal_rows):
            errors.append(f"fleet ledger {fleet_phase} completed count does not reconcile")
        started = len(
            {
                projections[attempt["attempt_id"]]["assignment_id"]
                for attempt in phase_attempts
            }
        )
        if record.get("started") != started:
            errors.append(f"fleet ledger {fleet_phase} started count does not reconcile")
        failed = sum(attempt["status"] != "completed" for attempt in phase_attempts)
        if record.get("failed") != failed:
            errors.append(f"fleet ledger {fleet_phase} failed attempt count does not reconcile")
    return errors


def iso_timestamp(value: Any) -> bool:
    if not nonempty_string(value):
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def parsed_timestamp(value: Any) -> Optional[datetime]:
    if not iso_timestamp(value):
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def claim_ttl_seconds() -> int:
    raw = os.environ.get("BARKPARK_TASK_LEASE_TTL_SECONDS", "")
    return int(raw) if raw.isdigit() and int(raw) > 0 else CLAIM_TTL_SECONDS


def captured_wish(path: Path) -> str:
    """Remove one documented capture-file terminator, preserving user whitespace."""
    wish = path.read_text(encoding="utf-8")
    if wish.endswith("\r\n"):
        return wish[:-2]
    if wish.endswith("\n"):
        return wish[:-1]
    return wish


def narrative_strings(blocks: list[dict[str, Any]]) -> list[str]:
    """Return reader-visible prose, excluding ids, URLs, alt text, and metadata."""
    def visible(value: Any) -> list[str]:
        if isinstance(value, str):
            return [value]
        if isinstance(value, list):
            return [text for child in value for text in visible(child)]
        if isinstance(value, dict):
            return [
                text
                for key in ("text", "value", "title", "content", "items", "children")
                if key in value
                for text in visible(value[key])
            ]
        return []

    return [
        text
        for block in blocks
        if isinstance(block, dict)
        for key in ("text", "title", "content", "items", "children")
        if key in block
        for text in visible(block[key])
    ]


def validate_fleet(paper: dict[str, Any], phase: str, require_debrief: bool) -> list[str]:
    fleet = next(
        (
            block.get("fleet")
            for block in paper_blocks(paper)
            if isinstance(block, dict) and isinstance(block.get("fleet"), dict)
        ),
        None,
    )
    if fleet is None:
        return ["paper has no structured Agent fleet record"]

    errors: list[str] = []
    required = set(REQUIRED_COMPLETIONS[phase])
    if phase == "review" and require_debrief:
        required.add("review")
    for fleet_phase, (agent_type, planned) in FLEET_SPECS.items():
        record = fleet.get(fleet_phase)
        if not isinstance(record, dict):
            errors.append(f"fleet has no {fleet_phase} record")
            continue
        if record.get("planned") != planned:
            errors.append(f"fleet {fleet_phase} planned count is not {planned}")
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
        valid_assignments = [
            assignment
            for assignment in assignments
            if isinstance(assignment, dict)
            and nonempty_string(assignment.get("id"))
            and assignment.get("agent_type") == agent_type
            and assignment.get("status") == "completed"
            and nonempty_string(assignment.get("evidence"))
        ]
        if len({assignment["id"] for assignment in valid_assignments}) != len(valid_assignments):
            errors.append(f"fleet {fleet_phase} contains duplicate assignment ids")
        if record.get("completed") != len(valid_assignments):
            errors.append(f"fleet {fleet_phase} completed count does not match typed evidence")
        if isinstance(started, int) and started < len(valid_assignments):
            errors.append(f"fleet {fleet_phase} started count is below completed count")
        missing = max(0, planned - len(valid_assignments))
        if record.get("missing") != missing:
            errors.append(f"fleet {fleet_phase} missing count is inconsistent")
        if len(valid_assignments) > planned:
            errors.append(f"fleet {fleet_phase} exceeds its exact {planned}-assignment contract")
        if fleet_phase in required and len(valid_assignments) < planned:
            errors.append(f"fleet {fleet_phase} requires {planned} completed typed assignments before {phase}")
    return errors


def paper_blocks(paper: dict[str, Any]) -> list[dict[str, Any]]:
    """Mirror Barkpark's top-level, content, then body Paper block fallback."""
    for candidate in (paper.get("blocks"), paper.get("content"), paper.get("body")):
        blocks = candidate.get("blocks") if isinstance(candidate, dict) else candidate
        if isinstance(blocks, list) and blocks:
            return blocks
    return []


def validate_canonical_cycle_projection(paper: dict[str, Any], args: argparse.Namespace) -> list[str]:
    """Pin canonical CycleFleet Papers to live authority unless legacy is explicit."""
    blocks = paper_blocks(paper)
    paper_ledger = next(
        (
            block.get("cycle_ledger")
            for block in blocks
            if isinstance(block, dict) and isinstance(block.get("cycle_ledger"), dict)
        ),
        None,
    )
    if paper_ledger is None:
        if getattr(args, "allow_pre_cyclefleet_paper_without_ledger", False):
            if getattr(args, "paper_json", None) is not None:
                return [
                    "legacy ledger omission requires live --paper retrieval; --paper-json "
                    "cannot prove immutable _createdAt metadata"
                ]
            created_at = parsed_timestamp(paper.get("_createdAt"))
            if created_at is not None and created_at.astimezone(timezone.utc) < CYCLEFLEET_PAPER_CUTOFF:
                return []
            return [
                "ledger-less Paper is not proven pre-CycleFleet: _createdAt must be an immutable "
                f"timestamp before {CYCLEFLEET_PAPER_CUTOFF.isoformat()}"
            ]
        return [
            "paper has no cycle_ledger; only a verified pre-CycleFleet Paper may use "
            "--allow-pre-cyclefleet-paper-without-ledger"
        ]

    paper_fleet = next(
        (
            block.get("fleet")
            for block in blocks
            if isinstance(block, dict) and isinstance(block.get("fleet"), dict)
        ),
        None,
    )
    errors: list[str] = []
    expected_profile = "legendary" if "experiment" in FLEET_SPECS else "epic"
    if paper_ledger.get("profile") != expected_profile:
        errors.append(f"canonical cycle ledger profile is not {expected_profile}")

    if getattr(args, "cycle_json", None):
        payload = load_json(args.cycle_json)
    else:
        scope = paper_ledger.get("scope")
        epic_id = scope.get("epic_id") if isinstance(scope, dict) else None
        wave_id = scope.get("wave_id") if isinstance(scope, dict) else None
        if not nonempty_string(epic_id) or not nonempty_string(wave_id):
            return errors + ["could not resolve the live CycleFleet authority for this Epic Paper"]
        workspace = getattr(args, "workspace", None)
        project = getattr(args, "project", None)
        if not nonempty_string(workspace) or not nonempty_string(project):
            return errors + [
                "live CycleFleet lookup requires explicit --workspace and --project scope"
            ]
        payload = command_json(
            "bp", "--workspace", workspace, "--project", project,
            "cycle", "show", epic_id, wave_id, "-o", "json"
        )

    live_ledger = payload.get("cycle_ledger") if isinstance(payload, dict) else None
    live_fleet = payload.get("fleet") if isinstance(payload, dict) else None
    if not isinstance(live_ledger, dict):
        errors.append("could not resolve the live CycleFleet authority for this Epic Paper")
    elif paper_ledger != live_ledger:
        errors.append("Epic Paper cycle_ledger does not exactly match the live CycleFleet authority")
    if not isinstance(live_fleet, dict):
        errors.append("could not resolve the live CycleFleet fleet for this Epic Paper")
    elif paper_fleet != live_fleet:
        errors.append("Epic Paper fleet does not exactly match the live CycleFleet authority")
    return errors


def validate(args: argparse.Namespace) -> list[str]:
    task_payload = load_json(args.task_json) if args.task_json else command_json("bp", "task", "get", args.task, "-o", "json")
    task = task_doc(task_payload)
    fields = task_fields(task)
    task_id = args.task or task.get("doc_id") or fields.get("_id", "").removeprefix("drafts.")
    if args.paper_json:
        paper = paper_doc(load_json(args.paper_json))
        paper_id = (paper.get("_id") or "").removeprefix("drafts.")
    else:
        paper_id = args.paper
        paper = paper_doc(command_json("bp", "doc", "get", "paper", paper_id, "-o", "json"))

    errors: list[str] = []
    if task.get("status") != "published":
        errors.append("task is not published")
    if fields.get("lifecycle_status") != "in_progress":
        errors.append("task lifecycle is not in_progress")
    claim = fields.get("claim") or task.get("claim") or {}
    if not isinstance(claim, dict):
        errors.append("task claim is not an object")
        claim = {}
    if not claim.get("worker"):
        errors.append("task has no active claim")
    if not args.worker:
        errors.append("preflight requires an expected worker")
    elif claim.get("worker") != args.worker:
        errors.append(f"task claim worker is {claim.get('worker')!r}, expected {args.worker!r}")
    if not isinstance(claim.get("epoch"), int) or claim["epoch"] < 1:
        errors.append("task claim epoch is missing or invalid")
    claim_ts = parsed_timestamp(claim.get("ts_iso"))
    if claim_ts is None:
        errors.append("task claim lease timestamp is missing or invalid")
    else:
        age = (datetime.now(timezone.utc) - claim_ts.astimezone(timezone.utc)).total_seconds()
        if age < -60 or age > claim_ttl_seconds():
            errors.append("task claim lease is not live; pulse and reread before preflight")
    root_strategize = args.phase == "strategize" and not fields.get("parent_id")
    if not fields.get("parent_id") and not root_strategize:
        errors.append("task has no parent epic")
    labels = fields.get("labels") or task.get("labels") or []
    if not has_label_value(labels, "proj:"):
        errors.append("task has no proj: label")
    if not has_label_value(labels, "phase:"):
        errors.append("task has no phase: label")
    if args.phase in {"build", "review"} and not has_label_value(labels, "files:"):
        errors.append("build task has no files: ownership label")
    criteria = fields.get("acceptance_criteria")
    valid_criteria = (
        isinstance(criteria, list)
        and bool(criteria)
        and all(isinstance(item, dict) and nonempty_string(item.get("criterion")) for item in criteria)
    )
    if not valid_criteria and not root_strategize:
        errors.append("task has no acceptance criteria")
    code_refs = fields.get("code_refs") or {}
    if not isinstance(code_refs, dict):
        errors.append("task code_refs is not an object")
        code_refs = {}
    if args.phase in {"build", "review"}:
        if not nonempty_string(code_refs.get("branch")):
            errors.append("task has no code_refs.branch")
        worktree_valid = nonempty_string(code_refs.get("worktree"))
        commits = code_refs.get("commits")
        commits_valid = isinstance(commits, list) and bool(commits) and all(nonempty_string(commit) for commit in commits)
        if commits is not None and commits != [] and not commits_valid:
            errors.append("task code_refs.commits is not a list of commit strings")
        if args.phase == "build" and not worktree_valid:
            errors.append("build task has no code_refs.worktree")
        if args.phase == "review" and not (worktree_valid or commits_valid):
            errors.append("review task has neither an active worktree nor an authoritative commit")
        if not iso_timestamp(fields.get("last_worked_at")):
            errors.append("task has no last_worked_at code activity timestamp")
    if fields.get("wave_paper") != paper_id:
        errors.append(f"task wave_paper is {fields.get('wave_paper')!r}, expected {paper_id!r}")

    actual_paper_id = (paper.get("_id") or "").removeprefix("drafts.")
    if paper.get("_draft") is not False:
        errors.append("paper is not published")
    if actual_paper_id != paper_id:
        errors.append(f"paper id is {actual_paper_id!r}, expected {paper_id!r}")
    headings = [
        str(block.get("text", "")).casefold()
        for block in paper_blocks(paper)
        if block.get("type") == "heading"
    ]
    for required in PHASE_HEADINGS[args.phase]:
        if not any(required in heading for heading in headings):
            errors.append(f"paper is missing required {args.phase} heading: {required}")
    errors.extend(validate_fleet(paper, args.phase, args.require_debrief))
    if args.phase in {"build", "review"}:
        ledger_path = getattr(args, "fleet_ledger_json", None)
        if ledger_path is None:
            errors.append("build/review preflight requires --fleet-ledger-json")
        else:
            try:
                ledger = load_canonical_ledger(ledger_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
                errors.append(f"fleet ledger export is invalid: {error}")
            else:
                errors.extend(validate_ledger(ledger, paper, fields.get("parent_id"), paper_id))
    errors.extend(validate_canonical_cycle_projection(paper, args))
    if args.require_debrief and not any("debrief" in heading for heading in headings):
        errors.append("paper is missing required post-review heading: debrief")
    if args.phase == "strategize" and not args.wish_file:
        errors.append("strategize preflight requires --wish-file")
    if args.wish_file:
        wish = captured_wish(args.wish_file)
        if not any(wish in value for value in narrative_strings(paper_blocks(paper))):
            errors.append("paper does not preserve the supplied wish verbatim")

    if args.pr_body:
        body = args.pr_body.read_text(encoding="utf-8")
        if re.search(r"\\n(?:\\n)?Task:", body):
            errors.append("PR body contains a literal escaped newline before its Task trailer")
        trailers = re.findall(r"^Task:[ \t]*(\S+)[ \t]*$", body, flags=re.MULTILINE)
        if trailers != [task_id]:
            errors.append(f"PR body must contain exactly one physical 'Task: {task_id}' line")
    return errors


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    task_source = result.add_mutually_exclusive_group(required=True)
    task_source.add_argument("--task")
    task_source.add_argument("--task-json", type=Path)
    paper_source = result.add_mutually_exclusive_group(required=True)
    paper_source.add_argument("--paper")
    paper_source.add_argument("--paper-json", type=Path)
    result.add_argument("--worker", required=True)
    result.add_argument("--phase", choices=PHASE_HEADINGS, default="build")
    result.add_argument("--require-debrief", action="store_true")
    result.add_argument("--fleet-ledger-json", type=Path)
    result.add_argument("--wish-file", type=Path)
    result.add_argument("--pr-body", type=Path)
    result.add_argument("--cycle-json", type=Path)
    result.add_argument("--workspace")
    result.add_argument("--project")
    result.add_argument(
        "--allow-pre-cyclefleet-paper-without-ledger",
        action="store_true",
        help=(
            "Explicit compatibility opt-in only with live --paper retrieval for a Paper whose "
            "immutable _createdAt is "
            f"before the CycleFleet cutoff {CYCLEFLEET_PAPER_CUTOFF.isoformat()}; canonical "
            "Papers must embed and verify cycle_ledger, and --paper-json cannot use this exception."
        ),
    )
    return result


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
    print("PASS: Epic Cycle Task, Paper, fleet ledger, and PR evidence satisfy the preflight contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
