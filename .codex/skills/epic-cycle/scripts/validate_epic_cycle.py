#!/usr/bin/env python3
"""Validate the machine-checkable Barkpark Epic Cycle preflight contract."""

from __future__ import annotations

import argparse
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

REQUIRED_COMPLETIONS = {
    "strategize": (),
    "digest": ("survey",),
    "decide": ("survey", "verify"),
    "build": ("survey", "verify"),
    "review": ("survey", "verify", "build"),
}

CLAIM_TTL_SECONDS = 2700


def command_json(*args: str) -> dict[str, Any]:
    result = subprocess.run(args, check=True, text=True, capture_output=True)
    return json.loads(result.stdout)


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


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
        if record.get("missing") != planned - len(valid_assignments):
            errors.append(f"fleet {fleet_phase} missing count is inconsistent")
        if fleet_phase in required and len(valid_assignments) != planned:
            errors.append(f"fleet {fleet_phase} requires {planned} completed typed assignments before {phase}")
    return errors


def paper_blocks(paper: dict[str, Any]) -> list[dict[str, Any]]:
    """Mirror Barkpark's top-level, content, then body Paper block fallback."""
    for candidate in (paper.get("blocks"), paper.get("content"), paper.get("body")):
        blocks = candidate.get("blocks") if isinstance(candidate, dict) else candidate
        if isinstance(blocks, list) and blocks:
            return blocks
    return []


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
    result.add_argument("--wish-file", type=Path)
    result.add_argument("--pr-body", type=Path)
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
    print("PASS: Epic Cycle Task, Paper, and PR evidence satisfy the preflight contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
