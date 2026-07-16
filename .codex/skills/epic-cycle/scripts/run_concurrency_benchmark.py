#!/usr/bin/env python3
"""Run the one supported Epic Cycle 1/2/3/6 concurrency benchmark.

The default command is deliberately plan-only.  Measured work requires the
``run`` or ``replay`` command, ``--execute-heavy``, a live tmux pane identity,
and a conservative host-admission decision.  This module is stdlib-only so its
schedule, admission, process fencing, and result analysis can be fixture tested
without launching a real benchmark.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
import platform
import random
import resource
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Optional, Sequence


SCHEMA_VERSION = "epic-cycle-concurrency-v1"
RETRIEVAL_SCHEMA_VERSION = "epic-cycle-concurrency-v2"
RETRIEVAL_SCHEMA_VERSION_V3 = "epic-cycle-concurrency-v3"
RETRIEVAL_CORPUS_SCHEMA_VERSION = "barkpark.retrieval-corpus.v1"
RETRIEVAL_CONTROL_SCHEMA_VERSION = "epic-cycle-control-proof-v2"
RETRIEVAL_ATTRIBUTION_SCHEMA_VERSION = "barkpark.epic-retrieval-attribution.v2"
RETRIEVAL_ATTRIBUTION_SCHEMA_VERSION_V3 = "barkpark.epic-retrieval-attribution.v3"
RETRIEVAL_CYCLE_PHASES = ("survey", "verify", "experiment", "build", "review")
RETRIEVAL_CORPUS_SHA256 = "a3a22c78d90e76fe00473b6434b2a025df51da7844d9022959c3f25eb0ee8a26"
RETRIEVAL_CORPUS_SHA256_SCOPE = "exact_file_bytes"
RETRIEVAL_REPO_COMMIT = "55519257db1377e4e747683204fe902fe8d562a9"
RETRIEVAL_UNIT_IDS = tuple(f"survey-2-1-{index:02d}" for index in range(1, 7))
SEED = 20260715
TREATMENTS = (1, 2, 3, 6)
ASSIGNMENT_COUNT = 6
WILLIAMS_ROWS = (
    (1, 2, 6, 3),
    (2, 3, 1, 6),
    (3, 6, 2, 1),
    (6, 1, 3, 2),
)
FIXED_LOOKS = (1, 2, 3, 4)
DEFAULT_HEAVY_CAPACITY = 1
MAX_HEAVY_CAPACITY = 2
MIN_AVAILABLE_BYTES = 512 * 1024 * 1024
CAPACITY_TWO_MIN_AVAILABLE_BYTES = 2 * 1024 * 1024 * 1024
COMPLETENESS_MARGIN_PP = 5.0
CONTRADICTION_MARGIN_PP = 2.0
FAILURE_MARGIN_PP = 5.0
SAMPLE_INTERVAL_SECONDS = 0.1
EXEC_GATE_CODE = """
import os
import sys
import time

gate = sys.argv[1]
deadline = time.monotonic() + 10.0
while not os.path.exists(gate):
    if time.monotonic() >= deadline:
        raise SystemExit(125)
    time.sleep(0.005)
argv = sys.argv[2:]
os.execvpe(argv[0], argv, os.environ)
"""


class ProtocolError(ValueError):
    """The frozen benchmark protocol or its input was violated."""


class SafetyError(RuntimeError):
    """A required process identity or execution-safety invariant failed."""


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    start_token: str
    platform: str
    source: str


@dataclass(frozen=True)
class HostSignals:
    pane: str
    pane_identity: Optional[ProcessIdentity]
    cpu_count: Optional[int]
    load1: Optional[float]
    memory_available_bytes: Optional[int]
    process_groups_supported: bool
    platform: str
    sources: Mapping[str, str]


@dataclass(frozen=True)
class AdmissionDecision:
    admitted: bool
    heavy_capacity: int
    reasons: tuple[str, ...]
    signals: HostSignals


@dataclass(frozen=True)
class PaneSnapshot:
    identities: Mapping[str, ProcessIdentity]
    missing: tuple[str, ...] = ()


@dataclass(frozen=True)
class GroupSample:
    pgid: int
    pids: tuple[int, ...]
    user_seconds: Optional[float]
    system_seconds: Optional[float]
    rss_bytes: Optional[int]
    cpu_percent: Optional[float]
    sources: Mapping[str, str]


def typed_metric(
    kind: str,
    *,
    value: Optional[float | int],
    unit: str,
    source: str,
    scope: str,
    reason: Optional[str] = None,
) -> dict[str, Any]:
    """Return a metric whose unknown state is never confused with numeric zero."""
    if kind not in {"measured", "null", "unsupported"}:
        raise ProtocolError(f"unknown metric kind: {kind}")
    if kind == "measured" and (value is None or isinstance(value, bool)):
        raise ProtocolError("measured metric requires a numeric value")
    if kind != "measured" and value is not None:
        raise ProtocolError(f"{kind} metric must have a null value")
    metric = {
        "kind": kind,
        "value": value,
        "unit": unit,
        "source": source,
        "scope": scope,
    }
    if reason:
        metric["reason"] = reason
    return metric


def measured(value: float | int, unit: str, source: str, scope: str) -> dict[str, Any]:
    return typed_metric("measured", value=value, unit=unit, source=source, scope=scope)


def null_metric(unit: str, source: str, scope: str, reason: str) -> dict[str, Any]:
    return typed_metric("null", value=None, unit=unit, source=source, scope=scope, reason=reason)


def unsupported_metric(unit: str, source: str, scope: str, reason: str) -> dict[str, Any]:
    return typed_metric("unsupported", value=None, unit=unit, source=source, scope=scope, reason=reason)


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest_json(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def complete_williams_rows(treatments: Sequence[int] = TREATMENTS) -> tuple[tuple[int, ...], ...]:
    """Return the complete even-treatment Williams cycle used by this runner."""
    if tuple(treatments) != TREATMENTS:
        raise ProtocolError("the sole supported treatment set is exactly 1/2/3/6")
    return WILLIAMS_ROWS


def validate_williams_cycle(rows: Sequence[Sequence[int]]) -> None:
    """Prove balance: every treatment and every directed carryover pair occurs equally."""
    expected = set(TREATMENTS)
    if len(rows) != len(TREATMENTS):
        raise ProtocolError("a complete Williams cycle requires four rows")
    pairs: dict[tuple[int, int], int] = {}
    for row in rows:
        if len(row) != len(TREATMENTS) or set(row) != expected:
            raise ProtocolError("each Williams row must contain 1/2/3/6 exactly once")
        for left, right in zip(row, row[1:]):
            pairs[(left, right)] = pairs.get((left, right), 0) + 1
    expected_pairs = {(left, right) for left in TREATMENTS for right in TREATMENTS if left != right}
    if set(pairs) != expected_pairs or set(pairs.values()) != {1}:
        raise ProtocolError("Williams cycle is not first-order carryover balanced")


def build_schedule(assignment_ids: Sequence[str], seed: int = SEED) -> list[dict[str, Any]]:
    """Freeze one complete Williams cycle and deterministic per-trial FIFO work order."""
    if seed != SEED:
        raise ProtocolError(f"benchmark seed is frozen at {SEED}")
    if len(assignment_ids) != ASSIGNMENT_COUNT or len(set(assignment_ids)) != ASSIGNMENT_COUNT:
        raise ProtocolError("benchmark requires exactly six uniquely named assignments")
    if not all(isinstance(item, str) and item.strip() for item in assignment_ids):
        raise ProtocolError("assignment ids must be non-empty strings")
    rows = complete_williams_rows()
    validate_williams_cycle(rows)
    rng = random.Random(seed)
    schedule: list[dict[str, Any]] = []
    for row_index, row in enumerate(rows, start=1):
        for position, width in enumerate(row, start=1):
            assignment_order = list(assignment_ids)
            rng.shuffle(assignment_order)
            schedule.append(
                {
                    "trial_id": f"look-{row_index}-position-{position}-width-{width}",
                    "look": row_index,
                    "williams_row": row_index,
                    "position": position,
                    "width": width,
                    "assignment_order": assignment_order,
                    "cold_reset": True,
                    "warm_prime": True,
                }
            )
    return schedule


def _validate_v1_manifest(manifest: Mapping[str, Any]) -> dict[str, Any]:
    """Validate and normalize the intentionally narrow benchmark manifest."""
    allowed = {
        "schema_version",
        "seed",
        "assignments",
        "cold_reset_argv",
        "warm_prime_argv",
        "primary_pane",
        "tmux_panes",
        "timeout_seconds",
        "environment",
    }
    unknown = sorted(set(manifest) - allowed)
    if unknown:
        raise ProtocolError(f"unsupported manifest fields: {', '.join(unknown)}")
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise ProtocolError(f"schema_version must be {SCHEMA_VERSION}")
    if manifest.get("seed", SEED) != SEED:
        raise ProtocolError(f"seed must be {SEED}")

    assignments = manifest.get("assignments")
    if not isinstance(assignments, list) or len(assignments) != ASSIGNMENT_COUNT:
        raise ProtocolError("manifest must contain exactly six assignments")
    normalized_assignments = []
    ids: list[str] = []
    for assignment in assignments:
        if not isinstance(assignment, dict) or set(assignment) != {"id", "argv"}:
            raise ProtocolError("each assignment must contain only id and argv")
        assignment_id = assignment.get("id")
        argv = assignment.get("argv")
        if not isinstance(assignment_id, str) or not assignment_id.strip():
            raise ProtocolError("assignment id must be a non-empty string")
        normalized_argv = validate_argv(argv, f"assignment {assignment_id}")
        ids.append(assignment_id)
        normalized_assignments.append({"id": assignment_id, "argv": normalized_argv})
    if len(set(ids)) != ASSIGNMENT_COUNT:
        raise ProtocolError("assignment ids must be unique")

    cold_reset = validate_argv(manifest.get("cold_reset_argv"), "cold reset")
    warm_prime = validate_argv(manifest.get("warm_prime_argv"), "warm prime")
    primary_pane = manifest.get("primary_pane") or os.environ.get("TMUX_PANE")
    if not isinstance(primary_pane, str) or not primary_pane.startswith("%"):
        raise ProtocolError("primary_pane must be an explicit tmux pane id such as %3")
    panes = manifest.get("tmux_panes", [primary_pane])
    if not isinstance(panes, list) or not panes or not all(isinstance(pane, str) and pane.startswith("%") for pane in panes):
        raise ProtocolError("tmux_panes must be a non-empty list of pane ids")
    if primary_pane not in panes:
        raise ProtocolError("tmux_panes must include primary_pane")
    timeout = manifest.get("timeout_seconds", 1800.0)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 0 < timeout <= 7200:
        raise ProtocolError("timeout_seconds must be in (0, 7200]")
    environment = manifest.get("environment", {})
    if not isinstance(environment, dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in environment.items()):
        raise ProtocolError("environment must map strings to strings")
    return {
        "schema_version": SCHEMA_VERSION,
        "seed": SEED,
        "assignments": normalized_assignments,
        "cold_reset_argv": cold_reset,
        "warm_prime_argv": warm_prime,
        "primary_pane": primary_pane,
        "tmux_panes": list(dict.fromkeys(panes)),
        "timeout_seconds": float(timeout),
        "environment": dict(environment),
    }


def validate_manifest(manifest: Mapping[str, Any]) -> dict[str, Any]:
    """Validate byte-stable v1 or one of the versioned retrieval protocols."""
    if is_retrieval_schema(manifest.get("schema_version")):
        return validate_retrieval_manifest(manifest)
    return _validate_v1_manifest(manifest)


def is_retrieval_schema(schema_version: Any) -> bool:
    return schema_version in {RETRIEVAL_SCHEMA_VERSION, RETRIEVAL_SCHEMA_VERSION_V3}


def validate_retrieval_manifest(manifest: Mapping[str, Any]) -> dict[str, Any]:
    schema_version = manifest.get("schema_version")
    if not is_retrieval_schema(schema_version):
        raise ProtocolError("retrieval schema_version is unsupported")
    allowed = {
        "schema_version",
        "seed",
        "assignments",
        "corpus",
        "cold_reset_argv",
        "warm_prime_argv",
        "primary_pane",
        "tmux_panes",
        "timeout_seconds",
        "environment",
    }
    unknown = sorted(set(manifest) - allowed)
    if unknown:
        raise ProtocolError(f"unsupported retrieval manifest fields: {', '.join(unknown)}")
    if manifest.get("seed", SEED) != SEED:
        raise ProtocolError(f"seed must be {SEED}")

    corpus_input = manifest.get("corpus")
    corpus = admit_retrieval_corpus(
        corpus_input,
        already_admitted=isinstance(corpus_input, dict) and "sha256_scope" in corpus_input,
    )
    assignments = manifest.get("assignments")
    if not isinstance(assignments, list) or len(assignments) != ASSIGNMENT_COUNT:
        raise ProtocolError("retrieval manifest must contain exactly six assignments")
    normalized_assignments = []
    ids: list[str] = []
    for assignment in assignments:
        if not isinstance(assignment, dict) or set(assignment) != {"id", "argv", "attribution"}:
            raise ProtocolError("each retrieval assignment must contain only id, argv, and attribution")
        assignment_id = assignment.get("id")
        if not isinstance(assignment_id, str) or not assignment_id:
            raise ProtocolError("retrieval assignment id must be a non-empty string")
        attribution = validate_cycle_attribution(
            assignment.get("attribution"),
            assignment_id,
            schema_version=schema_version,
        )
        ids.append(assignment_id)
        normalized_assignments.append(
            {
                "id": assignment_id,
                "argv": validate_argv(assignment.get("argv"), f"assignment {assignment_id}"),
                "attribution": attribution,
            }
        )
    if tuple(ids) != RETRIEVAL_UNIT_IDS or ids != corpus["unit_ids"]:
        raise ProtocolError("retrieval assignments must exactly match the preregistered corpus order")
    if len({assignment["attribution"]["cycle_assignment_uuid"] for assignment in normalized_assignments}) != ASSIGNMENT_COUNT:
        raise ProtocolError("cycle assignment UUIDs must be unique")
    scopes = {
        (assignment["attribution"]["epic_id"], assignment["attribution"]["wave_id"])
        for assignment in normalized_assignments
    }
    if len(scopes) != 1:
        raise ProtocolError("all retrieval assignments must belong to one epic/wave scope")

    # The v1 validator intentionally rejects every extra field. Rebuild only its
    # exact input rather than weakening that legacy boundary.
    common = _validate_v1_manifest(
        {
            key: value
            for key, value in {
                "schema_version": SCHEMA_VERSION,
                "seed": manifest.get("seed", SEED),
                "assignments": [
                    {"id": assignment["id"], "argv": assignment["argv"]}
                    for assignment in normalized_assignments
                ],
                "cold_reset_argv": manifest.get("cold_reset_argv"),
                "warm_prime_argv": manifest.get("warm_prime_argv"),
                "primary_pane": manifest.get("primary_pane"),
                "tmux_panes": manifest.get("tmux_panes"),
                "timeout_seconds": manifest.get("timeout_seconds", 1800.0),
                "environment": manifest.get("environment", {}),
            }.items()
            if value is not None
        }
    )
    return {
        **common,
        "schema_version": schema_version,
        "assignments": normalized_assignments,
        "corpus": corpus,
    }


def admit_retrieval_corpus(value: Any, *, already_admitted: bool = False) -> dict[str, Any]:
    admission_fields = {
        "path",
        "sha256",
        "repo_commit",
        "schema_version",
        "unit_ids",
    }
    if already_admitted:
        admission_fields.update({"sha256_scope", "claim_domain", "claim_domain_digest"})
    if not isinstance(value, dict) or set(value) != admission_fields:
        raise ProtocolError("retrieval corpus must contain the exact admission fields")
    if already_admitted and value.get("sha256_scope") != RETRIEVAL_CORPUS_SHA256_SCOPE:
        raise ProtocolError("retrieval corpus digest scope is not exact file bytes")
    path = value.get("path")
    if not isinstance(path, str) or not path:
        raise ProtocolError("retrieval corpus path must be non-empty")
    if value.get("sha256") != RETRIEVAL_CORPUS_SHA256:
        raise ProtocolError("retrieval corpus digest is not the preregistered digest")
    if value.get("repo_commit") != RETRIEVAL_REPO_COMMIT:
        raise ProtocolError("retrieval corpus commit is not the frozen commit")
    if value.get("schema_version") != RETRIEVAL_CORPUS_SCHEMA_VERSION:
        raise ProtocolError("retrieval corpus schema is unsupported")
    if tuple(value.get("unit_ids", ())) != RETRIEVAL_UNIT_IDS:
        raise ProtocolError("retrieval corpus unit ids are not the preregistered six")
    try:
        raw = Path(path).read_bytes()
    except OSError as error:
        raise ProtocolError(f"retrieval corpus is unavailable: {error}") from error
    actual_digest = hashlib.sha256(raw).hexdigest()
    if actual_digest != RETRIEVAL_CORPUS_SHA256:
        raise ProtocolError("retrieval corpus bytes do not match the preregistered digest")
    records = []
    try:
        for line in raw.decode("utf-8").splitlines():
            if not line:
                raise ProtocolError("retrieval corpus contains a blank record")
            records.append(json.loads(line))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProtocolError(f"retrieval corpus is not valid UTF-8 JSONL: {error}") from error
    if len(records) != ASSIGNMENT_COUNT:
        raise ProtocolError("retrieval corpus must contain exactly six records")
    if [record.get("id") for record in records] != list(RETRIEVAL_UNIT_IDS):
        raise ProtocolError("retrieval corpus records are not in preregistered order")
    for record in records:
        if record.get("schema_version") != RETRIEVAL_CORPUS_SCHEMA_VERSION:
            raise ProtocolError("retrieval corpus record schema mismatch")
        if record.get("repo", {}).get("commit") != RETRIEVAL_REPO_COMMIT:
            raise ProtocolError("retrieval corpus record commit mismatch")
        claims = record.get("gold_claims")
        sources = record.get("sources")
        if not isinstance(claims, list) or not claims or not isinstance(sources, list) or not sources:
            raise ProtocolError("retrieval corpus records require gold claims and sources")
        claim_ids = [claim.get("claim_id") for claim in claims if isinstance(claim, dict)]
        if (
            len(claim_ids) != len(claims)
            or any(not isinstance(claim_id, str) or not claim_id for claim_id in claim_ids)
            or len(claim_ids) != len(set(claim_ids))
        ):
            raise ProtocolError("retrieval corpus claim ids must be unique non-empty strings")
    claim_domain = {
        record["id"]: [claim["claim_id"] for claim in record["gold_claims"]]
        for record in records
    }
    claim_domain_digest = digest_json(claim_domain)
    if already_admitted and (
        value.get("claim_domain") != claim_domain
        or value.get("claim_domain_digest") != claim_domain_digest
    ):
        raise ProtocolError("retrieval corpus claim domain does not match exact file bytes")
    return {
        "path": str(Path(path).resolve()),
        "sha256": actual_digest,
        "sha256_scope": RETRIEVAL_CORPUS_SHA256_SCOPE,
        "repo_commit": RETRIEVAL_REPO_COMMIT,
        "schema_version": RETRIEVAL_CORPUS_SCHEMA_VERSION,
        "unit_ids": list(RETRIEVAL_UNIT_IDS),
        "claim_domain": claim_domain,
        "claim_domain_digest": claim_domain_digest,
    }


def validate_cycle_attribution(
    value: Any,
    assignment_id: str,
    *,
    schema_version: str = RETRIEVAL_SCHEMA_VERSION,
) -> dict[str, Any]:
    expected_keys = {
        "epic_id",
        "wave_id",
        "cycle_assignment_uuid",
        "assignment_id",
        "unit_ids",
        "inventory_digest",
        "snapshot_digest",
        "task",
    }
    if schema_version == RETRIEVAL_SCHEMA_VERSION_V3:
        expected_keys.add("cycle_phase")
    elif schema_version != RETRIEVAL_SCHEMA_VERSION:
        raise ProtocolError("retrieval schema_version is unsupported")
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise ProtocolError("cycle attribution has an invalid shape")
    if value.get("assignment_id") != assignment_id:
        raise ProtocolError("cycle attribution assignment mismatch")
    if schema_version == RETRIEVAL_SCHEMA_VERSION:
        if value.get("unit_ids") != [assignment_id]:
            raise ProtocolError("cycle attribution assignment/unit mismatch")
    else:
        cycle_phase = value.get("cycle_phase")
        if cycle_phase not in RETRIEVAL_CYCLE_PHASES:
            raise ProtocolError("cycle attribution phase is invalid")
        expected_unit_ids = [assignment_id] if cycle_phase == "build" else []
        if value.get("unit_ids") != expected_unit_ids:
            raise ProtocolError("cycle attribution phase/unit mismatch")
    for key in ("epic_id", "wave_id"):
        if not isinstance(value.get(key), str) or not value[key]:
            raise ProtocolError(f"cycle attribution {key} must be non-empty")
    try:
        parsed_uuid = str(uuid.UUID(value.get("cycle_assignment_uuid", "")))
    except (ValueError, TypeError, AttributeError) as error:
        raise ProtocolError("cycle assignment UUID is invalid") from error
    if parsed_uuid != value["cycle_assignment_uuid"]:
        raise ProtocolError("cycle assignment UUID must use canonical lowercase text")
    for key in ("inventory_digest", "snapshot_digest"):
        digest = value.get(key)
        if not isinstance(digest, str) or len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise ProtocolError(f"cycle attribution {key} must be lowercase SHA-256")
    task = value.get("task")
    if not isinstance(task, dict) or set(task) != {"doc_id", "worker_id", "claim_epoch", "work_digest"}:
        raise ProtocolError("cycle attribution task fence has an invalid shape")
    if not all(isinstance(task.get(key), str) and task[key] for key in ("doc_id", "worker_id")):
        raise ProtocolError("cycle attribution task identity is invalid")
    if isinstance(task.get("claim_epoch"), bool) or not isinstance(task.get("claim_epoch"), int) or task["claim_epoch"] < 1:
        raise ProtocolError("cycle attribution task claim epoch is invalid")
    work_digest = task.get("work_digest")
    if not isinstance(work_digest, str) or len(work_digest) != 16 or any(char not in "0123456789abcdef" for char in work_digest):
        raise ProtocolError("cycle attribution task work digest is invalid")
    return json.loads(canonical_json(value))


def validate_argv(argv: Any, label: str) -> list[str]:
    if not isinstance(argv, list) or not argv or not all(isinstance(item, str) and item for item in argv):
        raise ProtocolError(f"{label} argv must be a non-empty string list")
    return list(argv)


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ProtocolError("manifest root must be an object")
    return validate_manifest(value)


def plan_artifact(manifest: Mapping[str, Any]) -> dict[str, Any]:
    normalized = validate_manifest(manifest)
    ids = [assignment["id"] for assignment in normalized["assignments"]]
    frozen = {
        "schema_version": normalized["schema_version"],
        "seed": SEED,
        "treatments": list(TREATMENTS),
        "assignments_per_trial": ASSIGNMENT_COUNT,
        "williams_rows": [list(row) for row in WILLIAMS_ROWS],
        "fixed_looks": list(FIXED_LOOKS),
        "schedule": build_schedule(ids),
        "manifest_digest": digest_json(normalized),
    }
    if is_retrieval_schema(normalized["schema_version"]):
        corpus = normalized["corpus"]
        frozen["retrieval_admission"] = {
            key: corpus[key]
            for key in (
                "sha256",
                "sha256_scope",
                "repo_commit",
                "schema_version",
                "unit_ids",
                "claim_domain",
                "claim_domain_digest",
            )
        }
        frozen["attribution_contract_digest"] = digest_json(
            [assignment["attribution"] for assignment in normalized["assignments"]]
        )
    frozen["plan_digest"] = digest_json(frozen)
    return frozen


def verify_replay(plan: Mapping[str, Any], manifest: Mapping[str, Any]) -> None:
    expected = plan_artifact(manifest)
    if plan.get("schema_version") != expected["schema_version"]:
        raise ProtocolError("replay artifact has the wrong schema")
    supplied_digest = plan.get("plan_digest")
    without_digest = dict(plan)
    without_digest.pop("plan_digest", None)
    if supplied_digest != digest_json(without_digest):
        raise ProtocolError("replay artifact plan_digest is invalid")
    if canonical_json(plan) != canonical_json(expected):
        raise ProtocolError("replay artifact does not match the frozen manifest schedule")


def _run_text(argv: Sequence[str]) -> str:
    return subprocess.run(argv, check=True, text=True, capture_output=True).stdout


def resolve_tmux_pane_pid(pane: str, run_text: Callable[[Sequence[str]], str] = _run_text) -> int:
    output = run_text(("tmux", "display-message", "-p", "-t", pane, "#{pane_id}\t#{pane_pid}\t#{pane_dead}"))
    fields = output.strip().split("\t")
    if len(fields) != 3 or fields[0] != pane or fields[2] != "0" or not fields[1].isdigit():
        raise SafetyError(f"tmux pane {pane} is missing, dead, or has no live pid")
    pid = int(fields[1])
    if pid <= 1:
        raise SafetyError(f"tmux pane {pane} returned an unsafe pid")
    return pid


def parse_linux_stat(line: str) -> list[str]:
    closing = line.rfind(")")
    opening = line.find("(")
    if opening < 0 or closing <= opening or closing + 2 > len(line):
        raise SafetyError("malformed /proc stat record")
    pid = line[:opening].strip()
    if not pid.isdigit():
        raise SafetyError("malformed /proc stat pid")
    return [pid, line[opening + 1 : closing], *line[closing + 2 :].split()]


def read_process_identity(
    pid: int,
    *,
    system: Optional[str] = None,
    read_text: Optional[Callable[[Path], str]] = None,
    run_text: Callable[[Sequence[str]], str] = _run_text,
) -> ProcessIdentity:
    system = system or platform.system()
    if system == "Linux":
        reader = read_text or (lambda path: path.read_text(encoding="utf-8"))
        fields = parse_linux_stat(reader(Path(f"/proc/{pid}/stat")))
        if len(fields) < 22:
            raise SafetyError("/proc stat record lacks a process start field")
        return ProcessIdentity(pid, fields[21], "Linux", "/proc/<pid>/stat field 22")
    if system == "Darwin":
        value = run_text(("ps", "-o", "lstart=", "-p", str(pid))).strip()
        if not value:
            raise SafetyError("ps returned no process start time")
        return ProcessIdentity(pid, " ".join(value.split()), "Darwin", "ps -o lstart")
    raise SafetyError(f"unsupported process-fencing platform: {system}")


def identity_is_live(
    identity: ProcessIdentity,
    *,
    read_identity: Callable[..., ProcessIdentity] = read_process_identity,
) -> bool:
    try:
        current = read_identity(identity.pid, system=identity.platform)
    except (OSError, subprocess.SubprocessError, SafetyError):
        return False
    return current == identity


def read_memory_available_bytes(
    *,
    system: Optional[str] = None,
    read_text: Optional[Callable[[Path], str]] = None,
    run_text: Callable[[Sequence[str]], str] = _run_text,
) -> tuple[Optional[int], str]:
    system = system or platform.system()
    if system == "Linux":
        reader = read_text or (lambda path: path.read_text(encoding="utf-8"))
        for line in reader(Path("/proc/meminfo")).splitlines():
            if line.startswith("MemAvailable:"):
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    return int(parts[1]) * 1024, "/proc/meminfo MemAvailable"
        return None, "/proc/meminfo MemAvailable missing"
    if system == "Darwin":
        output = run_text(("vm_stat",))
        page_size = 4096
        available_pages = 0
        for line in output.splitlines():
            if "page size of" in line:
                words = line.replace("bytes", "").split()
                numeric = [int(word) for word in words if word.isdigit()]
                if numeric:
                    page_size = numeric[-1]
            elif line.startswith(("Pages free:", "Pages inactive:", "Pages speculative:")):
                raw = line.split(":", 1)[1].strip().rstrip(".")
                if raw.isdigit():
                    available_pages += int(raw)
        return (available_pages * page_size if available_pages else None), "vm_stat free+inactive+speculative"
    return None, f"unsupported platform {system}"


def capture_host_signals(
    pane: str,
    *,
    system: Optional[str] = None,
    pane_pid_resolver: Callable[[str], int] = resolve_tmux_pane_pid,
    identity_reader: Callable[..., ProcessIdentity] = read_process_identity,
    memory_reader: Callable[..., tuple[Optional[int], str]] = read_memory_available_bytes,
) -> HostSignals:
    system = system or platform.system()
    sources: dict[str, str] = {}
    identity: Optional[ProcessIdentity]
    try:
        pane_pid = pane_pid_resolver(pane)
        identity = identity_reader(pane_pid, system=system)
        sources["pane_identity"] = identity.source
    except (OSError, subprocess.SubprocessError, SafetyError) as error:
        identity = None
        sources["pane_identity"] = f"unavailable: {error}"
    try:
        load1 = float(os.getloadavg()[0])
        sources["load1"] = "os.getloadavg"
    except (AttributeError, OSError):
        load1 = None
        sources["load1"] = "os.getloadavg unavailable"
    memory, memory_source = memory_reader(system=system)
    sources["memory_available_bytes"] = memory_source
    cpu_count = os.cpu_count()
    sources["cpu_count"] = "os.cpu_count"
    groups_supported = system in {"Linux", "Darwin"} and all(
        hasattr(os, name) for name in ("getpgid", "killpg", "setsid")
    )
    sources["process_groups_supported"] = "POSIX start_new_session/getpgid/killpg"
    return HostSignals(pane, identity, cpu_count, load1, memory, groups_supported, system, sources)


def admit_heavy_run(
    signals: HostSignals,
    requested_capacity: int = DEFAULT_HEAVY_CAPACITY,
    *,
    capacity_two_explicit: bool = False,
) -> AdmissionDecision:
    reasons: list[str] = []
    if requested_capacity not in {1, 2}:
        reasons.append("heavy capacity must be one or two")
    if requested_capacity == 2 and not capacity_two_explicit:
        reasons.append("capacity two requires the explicit --allow-capacity-two flag")
    if signals.pane_identity is None:
        reasons.append("live tmux pane identity is missing")
    if signals.platform not in {"Linux", "Darwin"}:
        reasons.append("Darwin or Linux process-start fencing is required")
    if not signals.process_groups_supported:
        reasons.append("owned POSIX process groups are unavailable")
    if not isinstance(signals.cpu_count, int) or signals.cpu_count < 1:
        reasons.append("cpu_count safety signal is missing")
    if signals.load1 is None or not math.isfinite(signals.load1) or signals.load1 < 0:
        reasons.append("load1 safety signal is missing")
    if not isinstance(signals.memory_available_bytes, int) or signals.memory_available_bytes < 0:
        reasons.append("available-memory safety signal is missing")
    if reasons:
        return AdmissionDecision(False, requested_capacity, tuple(reasons), signals)

    assert signals.cpu_count is not None
    assert signals.load1 is not None
    assert signals.memory_available_bytes is not None
    if signals.memory_available_bytes < MIN_AVAILABLE_BYTES:
        reasons.append(f"available memory is below {MIN_AVAILABLE_BYTES} bytes")
    if signals.load1 > signals.cpu_count * 1.5:
        reasons.append("host load exceeds the capacity-one safety ceiling")
    if requested_capacity == 2:
        if signals.cpu_count < 4:
            reasons.append("capacity two requires at least four logical CPUs")
        if signals.memory_available_bytes < CAPACITY_TWO_MIN_AVAILABLE_BYTES:
            reasons.append(f"capacity two requires at least {CAPACITY_TWO_MIN_AVAILABLE_BYTES} available bytes")
        if signals.load1 > signals.cpu_count * 0.75:
            reasons.append("capacity two requires load1 no greater than 75% of logical CPUs")
    return AdmissionDecision(not reasons, requested_capacity, tuple(reasons), signals)


def capture_pane_snapshot(
    panes: Sequence[str],
    *,
    pid_resolver: Callable[[str], int] = resolve_tmux_pane_pid,
    identity_reader: Callable[..., ProcessIdentity] = read_process_identity,
    system: Optional[str] = None,
) -> PaneSnapshot:
    identities: dict[str, ProcessIdentity] = {}
    missing: list[str] = []
    for pane in panes:
        try:
            pid = pid_resolver(pane)
            identities[pane] = identity_reader(pid, system=system or platform.system())
        except (OSError, subprocess.SubprocessError, SafetyError):
            missing.append(pane)
    return PaneSnapshot(identities, tuple(sorted(missing)))


def contamination_reasons(before: PaneSnapshot, after: PaneSnapshot, primary_pane: str) -> list[str]:
    reasons: list[str] = []
    if primary_pane not in before.identities or primary_pane not in after.identities:
        reasons.append("primary pane identity missing")
    elif before.identities[primary_pane] != after.identities[primary_pane]:
        reasons.append("primary pane pid/start identity changed")
    all_panes = set(before.identities) | set(after.identities) | set(before.missing) | set(after.missing)
    for pane in sorted(all_panes - {primary_pane}):
        if before.identities.get(pane) != after.identities.get(pane):
            reasons.append(f"ambient pane identity changed: {pane}")
    return reasons


def assert_primary_fence(snapshot: PaneSnapshot, pane: str, expected: ProcessIdentity) -> None:
    current = snapshot.identities.get(pane)
    if current != expected:
        raise SafetyError("primary tmux pane pid/start fence changed after host admission")


def execution_contamination_reasons(payload: Mapping[str, Any]) -> list[str]:
    reasons: list[str] = []
    sampler = payload.get("sampler")
    if isinstance(sampler, dict):
        errors = sampler.get("errors")
        if not isinstance(errors, list):
            reasons.append("sampler error record is malformed")
        else:
            reasons.extend(f"owned process-group sampler error: {error}" for error in errors)
    contaminated_groups = payload.get("process_group_contamination")
    if contaminated_groups is not None:
        if not isinstance(contaminated_groups, list):
            reasons.append("owned process-group contamination record is malformed")
        else:
            reasons.extend(
                f"owned process group had live members after its leader exited: {pgid}"
                for pgid in contaminated_groups
            )
    return reasons


def parse_linux_group_sample(lines: Iterable[str], pgid: int, clock_ticks: int, page_size: int) -> GroupSample:
    pids: list[int] = []
    user_ticks = 0
    system_ticks = 0
    rss_pages = 0
    for line in lines:
        try:
            fields = parse_linux_stat(line)
            if len(fields) < 24 or int(fields[4]) != pgid:
                continue
            pids.append(int(fields[0]))
            user_ticks += int(fields[13])
            system_ticks += int(fields[14])
            rss_pages += max(0, int(fields[23]))
        except (ValueError, SafetyError):
            continue
    observed = bool(pids)
    return GroupSample(
        pgid,
        tuple(sorted(pids)),
        user_ticks / clock_ticks if observed else None,
        system_ticks / clock_ticks if observed else None,
        rss_pages * page_size if observed else None,
        None,
        {
            "user_seconds": "/proc/<pid>/stat utime",
            "system_seconds": "/proc/<pid>/stat stime",
            "rss_bytes": "/proc/<pid>/stat rss",
            "cpu_percent": "derived after interval; not sampled here",
        },
    )


def sample_process_group(pgid: int, *, system: Optional[str] = None) -> GroupSample:
    system = system or platform.system()
    if system == "Linux":
        lines: list[str] = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                lines.append((entry / "stat").read_text(encoding="utf-8"))
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
        return parse_linux_group_sample(
            lines,
            pgid,
            int(os.sysconf("SC_CLK_TCK")),
            int(os.sysconf("SC_PAGE_SIZE")),
        )
    if system == "Darwin":
        output = _run_text(("ps", "-axo", "pid=,pgid=,rss=,%cpu="))
        pids: list[int] = []
        rss_kib = 0
        cpu_percent = 0.0
        for line in output.splitlines():
            fields = line.split()
            if len(fields) != 4:
                continue
            try:
                pid_value, pgid_value, rss_value = map(int, fields[:3])
                cpu_value = float(fields[3])
            except ValueError:
                continue
            if pgid_value == pgid:
                pids.append(pid_value)
                rss_kib += max(0, rss_value)
                cpu_percent += max(0.0, cpu_value)
        observed = bool(pids)
        return GroupSample(
            pgid,
            tuple(sorted(pids)),
            None,
            None,
            rss_kib * 1024 if observed else None,
            cpu_percent if observed else None,
            {
                "user_seconds": "unsupported by portable Darwin ps group sample",
                "system_seconds": "unsupported by portable Darwin ps group sample",
                "rss_bytes": "ps -axo rss",
                "cpu_percent": "ps -axo %cpu",
            },
        )
    raise SafetyError(f"unsupported sampler platform: {system}")


class OwnedGroupSampler:
    """Sample only process groups created and registered by this runner."""

    def __init__(self, sample: Callable[[int], GroupSample] = sample_process_group) -> None:
        self._sample = sample
        self._pgids: set[int] = set()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self.peak_rss_bytes: Optional[int] = None
        self.peak_cpu_percent: Optional[float] = None
        self.sample_count = 0
        self.errors: list[str] = []

    def register(self, pgid: int) -> None:
        with self._lock:
            self._pgids.add(pgid)

    def start(self) -> None:
        if self._thread is not None:
            raise SafetyError("sampler already started")
        self._thread = threading.Thread(target=self._loop, name="owned-pgid-sampler", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2.0)

    def _loop(self) -> None:
        while not self._stop.is_set():
            with self._lock:
                pgids = tuple(self._pgids)
            rss_total = 0
            cpu_total = 0.0
            rss_known = False
            cpu_known = False
            for pgid in pgids:
                try:
                    sample = self._sample(pgid)
                except (OSError, subprocess.SubprocessError, SafetyError) as error:
                    self.errors.append(f"pgid {pgid}: {error}")
                    continue
                if sample.rss_bytes is not None:
                    rss_total += sample.rss_bytes
                    rss_known = True
                if sample.cpu_percent is not None:
                    cpu_total += sample.cpu_percent
                    cpu_known = True
            if rss_known:
                self.peak_rss_bytes = max(self.peak_rss_bytes or 0, rss_total)
            if cpu_known:
                self.peak_cpu_percent = max(self.peak_cpu_percent or 0.0, cpu_total)
            self.sample_count += 1
            self._stop.wait(SAMPLE_INTERVAL_SECONDS)


def _rusage_snapshot() -> tuple[float, float]:
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime, usage.ru_stime


def _parse_assignment_evaluation(stdout: str) -> tuple[Optional[bool], Optional[bool], str]:
    """Read the final non-empty stdout line as the narrow evaluation contract."""
    lines = [line for line in stdout.splitlines() if line.strip()]
    if not lines:
        return None, None, "assignment emitted no JSON evaluation"
    try:
        value = json.loads(lines[-1])
    except json.JSONDecodeError:
        return None, None, "assignment final stdout line is not JSON"
    if not isinstance(value, dict):
        return None, None, "assignment evaluation is not an object"
    complete = value.get("complete")
    contradiction = value.get("contradiction_unsupported")
    if not isinstance(complete, bool) or not isinstance(contradiction, bool):
        return None, None, "evaluation requires boolean complete and contradiction_unsupported"
    return complete, contradiction, ""


def typed_observation(state: str, *, value: Optional[int] = None, unit: str, reason: Optional[str] = None, **extra: Any) -> dict[str, Any]:
    """Return the v2 ledger state vocabulary without coercing unknowns to zero."""
    if state not in {"observed", "unsupported", "missing", "invalid"}:
        raise ProtocolError(f"unknown observation state: {state}")
    if state == "observed":
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ProtocolError("observed retrieval values require a non-negative integer")
        result = {"state": state, "value": value, "unit": unit}
    else:
        if value is not None or not isinstance(reason, str) or not reason:
            raise ProtocolError(f"{state} retrieval values require only a reason")
        result = {"state": state, "reason": reason, "unit": unit}
    result.update(extra)
    return result


def retrieval_record(corpus: Mapping[str, Any], assignment_id: str) -> dict[str, Any]:
    admitted = admit_retrieval_corpus(corpus, already_admitted=True)
    raw = Path(admitted["path"]).read_text(encoding="utf-8")
    for line in raw.splitlines():
        record = json.loads(line)
        if record.get("id") == assignment_id:
            return record
    raise ProtocolError(f"retrieval corpus has no record for {assignment_id}")


def score_vui(record: Mapping[str, Any], witnesses: Any) -> tuple[dict[str, Any], bool]:
    """Score preregistered claim witnesses; prose similarity never earns credit."""
    claims = record.get("gold_claims")
    if not isinstance(witnesses, list):
        return typed_observation("missing", unit="claims", reason="witnesses are absent"), True
    gold = {claim.get("claim_id"): claim for claim in claims if isinstance(claim, dict)}
    seen: dict[str, Mapping[str, Any]] = {}
    for witness in witnesses:
        if not isinstance(witness, dict) or set(witness) != {"claim_id", "verdict", "evidence"}:
            return typed_observation("invalid", unit="claims", reason="witness shape is invalid"), True
        claim_id = witness.get("claim_id")
        if claim_id not in gold:
            return typed_observation("invalid", unit="claims", reason="witness names an unknown claim"), True
        if claim_id in seen:
            return typed_observation("invalid", unit="claims", reason="duplicate claim witness"), True
        verdict = witness.get("verdict")
        evidence = witness.get("evidence")
        if verdict not in {"supported", "contradicted", "unsupported"}:
            return typed_observation("invalid", unit="claims", reason="witness verdict is invalid"), True
        if not isinstance(evidence, list) or not evidence or len(evidence) != len(set(evidence)):
            return typed_observation("invalid", unit="claims", reason="witness evidence is absent or duplicated"), True
        if not all(item in gold[claim_id].get("evidence", []) for item in evidence):
            return typed_observation("invalid", unit="claims", reason="witness evidence is outside the frozen gold set"), True
        seen[claim_id] = witness

    missing = sorted(set(gold) - set(seen))
    contradicted = sorted(
        claim_id for claim_id, witness in seen.items() if witness["verdict"] == "contradicted"
    )
    unsupported = sorted(
        claim_id for claim_id, witness in seen.items() if witness["verdict"] == "unsupported"
    )
    verified = sorted(
        claim_id for claim_id, witness in seen.items() if witness["verdict"] == "supported"
    )
    detail = {
        "verified_claim_ids": verified,
        "missing_claim_ids": missing,
        "contradicted_claim_ids": contradicted,
        "unsupported_claim_ids": unsupported,
    }
    if contradicted:
        return typed_observation("invalid", unit="claims", reason="gold claim contradicted", **detail), True
    if missing:
        return typed_observation("missing", unit="claims", reason="gold claim witness absent", **detail), True
    if unsupported:
        return typed_observation("unsupported", unit="claims", reason="gold claim unsupported", **detail), True
    return typed_observation("observed", value=len(verified), unit="claims", **detail), False


def validate_usage_receipt(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or "state" not in value:
        return typed_observation("missing", unit="tokens", reason="provider usage receipt is absent")
    state = value.get("state")
    if state in {"unsupported", "missing", "invalid"}:
        if set(value) != {"state", "reason"} or not isinstance(value.get("reason"), str) or not value["reason"]:
            return typed_observation("invalid", unit="tokens", reason="typed provider usage state is malformed")
        return typed_observation(state, unit="tokens", reason=value["reason"])
    expected = {
        "state",
        "provider_session_id",
        "provider_turn_id",
        "counter_domain",
        "baseline_tokens",
        "terminal_tokens",
        "token_count",
        "context_occupancy",
    }
    if state != "observed" or set(value) != expected:
        return typed_observation("invalid", unit="tokens", reason="observed provider usage receipt has an invalid shape")
    opaque = (value.get("provider_session_id"), value.get("provider_turn_id"), value.get("counter_domain"))
    if not all(
        isinstance(item, str)
        and item
        and len(item) <= 200
        and all(char.isalnum() or char in "._:-" for char in item)
        for item in opaque
    ):
        return typed_observation("invalid", unit="tokens", reason="provider usage identity is not opaque allowlisted text")
    baseline = value.get("baseline_tokens")
    terminal = value.get("terminal_tokens")
    token_count = value.get("token_count")
    if (
        isinstance(baseline, bool)
        or not isinstance(baseline, int)
        or baseline < 0
        or isinstance(terminal, bool)
        or not isinstance(terminal, int)
        or terminal < baseline
        or not isinstance(token_count, dict)
        or token_count != {"state": "observed", "value": terminal - baseline}
    ):
        return typed_observation("invalid", unit="tokens", reason="provider counters are non-monotonic or inconsistent")
    context = value.get("context_occupancy")
    if not isinstance(context, dict) or set(context) not in ({"state", "value"}, {"state", "reason"}):
        return typed_observation("invalid", unit="tokens", reason="context occupancy state is malformed")
    if context.get("state") == "observed":
        context_value = context.get("value")
        if isinstance(context_value, bool) or not isinstance(context_value, int) or context_value < 0:
            return typed_observation("invalid", unit="tokens", reason="context occupancy value is invalid")
    elif context.get("state") not in {"unsupported", "missing", "invalid"} or not isinstance(context.get("reason"), str) or not context["reason"]:
        return typed_observation("invalid", unit="tokens", reason="context occupancy state is invalid")
    return json.loads(canonical_json(value))


def parse_retrieval_evaluation(
    stdout: str,
    record: Mapping[str, Any],
    expected_attribution: Mapping[str, Any],
) -> dict[str, Any]:
    lines = [line for line in stdout.splitlines() if line.strip()]
    if not lines:
        return {
            "complete": False,
            "contradiction_unsupported": True,
            "vui": typed_observation("missing", unit="claims", reason="assignment emitted no evaluation"),
            "usage": typed_observation("missing", unit="tokens", reason="assignment emitted no evaluation"),
            "attribution": None,
            "reason": "assignment emitted no JSON evaluation",
        }
    try:
        value = json.loads(lines[-1])
    except json.JSONDecodeError:
        value = None
    if not isinstance(value, dict) or set(value) != {"complete", "witnesses", "attribution", "usage"}:
        return {
            "complete": False,
            "contradiction_unsupported": True,
            "vui": typed_observation("invalid", unit="claims", reason="retrieval evaluation shape is invalid"),
            "usage": typed_observation("invalid", unit="tokens", reason="retrieval evaluation shape is invalid"),
            "attribution": None,
            "reason": "retrieval evaluation shape is invalid",
        }
    if not isinstance(value.get("complete"), bool):
        return {
            "complete": False,
            "contradiction_unsupported": True,
            "vui": typed_observation("invalid", unit="claims", reason="complete must be boolean"),
            "usage": typed_observation("invalid", unit="tokens", reason="complete must be boolean"),
            "attribution": None,
            "reason": "complete must be boolean",
        }
    if value.get("attribution") != expected_attribution:
        return {
            "complete": False,
            "contradiction_unsupported": True,
            "vui": typed_observation("invalid", unit="claims", reason="cycle/task attribution mismatch"),
            "usage": typed_observation("invalid", unit="tokens", reason="cycle/task attribution mismatch"),
            "attribution": None,
            "reason": "cycle/task attribution mismatch",
        }
    vui, contradiction = score_vui(record, value.get("witnesses"))
    usage = validate_usage_receipt(value.get("usage"))
    complete = value["complete"] and vui["state"] == "observed"
    return {
        "complete": complete,
        "contradiction_unsupported": contradiction,
        "vui": vui,
        "usage": usage,
        "attribution": json.loads(canonical_json(expected_attribution)),
        "reason": "" if complete else "retrieval evidence is incomplete, contradictory, or unsupported",
    }


def launch_owned_process(
    argv: Sequence[str],
    *,
    env: Mapping[str, str],
    stdout_path: Path,
    stderr_path: Path,
) -> tuple[subprocess.Popen[str], ProcessIdentity, int]:
    stdout_handle = stdout_path.open("w", encoding="utf-8")
    stderr_handle = stderr_path.open("w", encoding="utf-8")
    gate_path = stdout_path.with_suffix(stdout_path.suffix + ".start")
    try:
        process = subprocess.Popen(
            [sys.executable, "-c", EXEC_GATE_CODE, str(gate_path), *argv],
            stdin=subprocess.DEVNULL,
            stdout=stdout_handle,
            stderr=stderr_handle,
            text=True,
            env=dict(env),
            start_new_session=True,
        )
    except BaseException:
        stdout_handle.close()
        stderr_handle.close()
        raise
    finally:
        # Popen owns duplicated descriptors; parent copies can close immediately.
        if "process" in locals():
            stdout_handle.close()
            stderr_handle.close()
    try:
        identity = read_process_identity(process.pid)
        pgid = os.getpgid(process.pid)
        if pgid != process.pid:
            raise SafetyError("child did not become leader of its owned process group")
        if not identity_is_live(identity):
            raise SafetyError("child process identity could not be fenced after launch")
        gate_path.touch(exist_ok=False)
    except BaseException:
        # start_new_session makes the child pid its pgid before the exec gate;
        # drain the group even when the leader already exited during fencing.
        terminate_owned_group(process.pid, leader=process)
        raise
    return process, identity, pgid


def process_group_exists(pgid: int) -> bool:
    """Return whether the owned process group still has signal-visible members."""
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # An owned group should remain signalable. Treat an unexpected EPERM as
        # existing so callers cannot mistake an unverifiable group for drained.
        return True
    return True


def wait_for_process_group_disappearance(pgid: int, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while process_group_exists(pgid):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)
    return True


def terminate_owned_group(
    pgid: int,
    grace_seconds: float = 1.0,
    *,
    leader: Optional[subprocess.Popen[str]] = None,
) -> None:
    """Terminate an owned group and prove no signal-visible member remains."""
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except PermissionError:
        # Darwin can report EPERM for a newly orphaned/zombie process group.
        # The group leader has the same pid by construction, so retain a
        # leader-directed fallback rather than abandoning a live child.
        try:
            os.kill(pgid, signal.SIGTERM)
        except ProcessLookupError:
            return
    if leader is not None:
        try:
            leader.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            pass
    if wait_for_process_group_disappearance(pgid, grace_seconds):
        return
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except PermissionError:
        try:
            os.kill(pgid, signal.SIGKILL)
        except ProcessLookupError:
            return
    if leader is not None:
        try:
            leader.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired as error:
            raise SafetyError(
                f"owned process-group leader {pgid} did not exit after SIGKILL"
            ) from error
    if not wait_for_process_group_disappearance(pgid, grace_seconds):
        raise SafetyError(
            f"owned process group {pgid} did not disappear after SIGTERM/SIGKILL"
        )


def drain_group_after_leader_exit(pgid: int) -> dict[str, Any]:
    """Classify a terminal leader's group, cleaning any surviving members."""
    if not process_group_exists(pgid):
        return {
            "status": "clean",
            "action": "none",
            "verified_disappearance": True,
        }
    terminate_owned_group(pgid)
    return {
        "status": "contaminated",
        "action": "SIGTERM/SIGKILL as needed",
        "verified_disappearance": True,
    }


def run_control_command(
    argv: Sequence[str],
    env: Mapping[str, str],
    timeout_seconds: float,
    label: str,
    *,
    semantic_state: Optional[str] = None,
    corpus: Optional[Mapping[str, Any]] = None,
) -> dict[str, Any]:
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="epic-cycle-control-") as temporary:
        root = Path(temporary)
        stdout_path = root / "stdout"
        stderr_path = root / "stderr"
        process: Optional[subprocess.Popen[str]] = None
        pgid: Optional[int] = None
        try:
            process, process_identity, pgid = launch_owned_process(
                argv,
                env=env,
                stdout_path=stdout_path,
                stderr_path=stderr_path,
            )
            try:
                returncode = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired as error:
                terminate_owned_group(pgid, leader=process)
                raise SafetyError(f"{label} timed out after {timeout_seconds}s") from error
            group_cleanup = drain_group_after_leader_exit(pgid)
            if group_cleanup["status"] != "clean":
                raise SafetyError(
                    f"{label} leader exited with {returncode} but left live members "
                    f"in owned process group {pgid}; the group was terminated and disappearance verified"
                )
            if returncode != 0:
                stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
                raise SafetyError(f"{label} failed with exit {returncode}: {stderr[-500:]}")
            result = {
                "status": "passed",
                "wall_seconds": time.monotonic() - started,
                "process_identity": asdict(process_identity),
                "pgid": pgid,
            }
            if semantic_state is not None:
                if corpus is None:
                    raise SafetyError(f"{label} semantic proof has no admitted corpus")
                stdout = stdout_path.read_text(encoding="utf-8", errors="replace")
                result["semantic_verification"] = validate_control_proof(
                    stdout, semantic_state, corpus
                )
            return result
        finally:
            if process is not None and process.poll() is None and pgid is not None:
                terminate_owned_group(pgid, leader=process)


def validate_control_proof(stdout: str, expected_state: str, corpus: Mapping[str, Any]) -> dict[str, Any]:
    if expected_state not in {"cold", "warm"}:
        raise ProtocolError(f"unsupported semantic control state: {expected_state}")
    return unsupported_metric(
        "boolean",
        f"declared {expected_state} preparation command",
        f"pre-treatment {expected_state} state for exact-byte corpus {corpus['sha256']}",
        "command stdout is self-reported and cannot independently establish generic cache state",
    )


class HeavyCapacityLease:
    """Cross-process lease: capacity one is exclusive; capacity two shares two slots."""

    def __init__(self, capacity: int, root: Optional[Path] = None) -> None:
        if capacity not in {1, 2}:
            raise ProtocolError("heavy capacity lease supports only one or two")
        self.capacity = capacity
        self.root = root or Path(tempfile.gettempdir()) / "barkpark-epic-cycle-concurrency"
        self._gate: Optional[Any] = None
        self._slot: Optional[Any] = None
        self.slot_index: Optional[int] = None

    def __enter__(self) -> "HeavyCapacityLease":
        self.root.mkdir(parents=True, exist_ok=True)
        self._gate = (self.root / "capacity.gate").open("a+")
        gate_mode = fcntl.LOCK_EX if self.capacity == 1 else fcntl.LOCK_SH
        try:
            fcntl.flock(self._gate.fileno(), gate_mode | fcntl.LOCK_NB)
        except BlockingIOError as error:
            self._gate.close()
            self._gate = None
            raise SafetyError("heavy capacity is already occupied by an incompatible run") from error
        for index in range(self.capacity):
            handle = (self.root / f"slot-{index}.lock").open("a+")
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                handle.close()
                continue
            self._slot = handle
            self.slot_index = index
            return self
        self.__exit__(None, None, None)
        raise SafetyError(f"all {self.capacity} admitted heavy-capacity slots are occupied")

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        for handle in (self._slot, self._gate):
            if handle is not None:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                handle.close()
        self._slot = None
        self._gate = None
        self.slot_index = None


def reject_duplicate_usage_identities(results: Sequence[dict[str, Any]]) -> None:
    seen: dict[tuple[str, str], dict[str, Any]] = {}
    for result in results:
        usage = result.get("usage")
        if not isinstance(usage, dict) or usage.get("state") != "observed":
            continue
        identity = (usage["provider_session_id"], usage["provider_turn_id"])
        previous = seen.get(identity)
        if previous is None:
            seen[identity] = result
            continue
        for duplicate in (previous, result):
            duplicate["complete"] = False
            duplicate["contradiction_unsupported"] = True
            duplicate["usage"] = typed_observation(
                "invalid", unit="tokens", reason="duplicate provider session/turn attribution"
            )
            duplicate["reason"] = "duplicate provider session/turn attribution"


def aggregate_typed_observations(
    results: Sequence[Mapping[str, Any]], field: str, unit: str
) -> dict[str, Any]:
    observations = [result.get(field) for result in results]
    states = [value.get("state") for value in observations if isinstance(value, dict)]
    for state in ("invalid", "missing", "unsupported"):
        if state in states:
            return typed_observation(
                state,
                unit=unit,
                reason=f"one or more assignment {field} observations are {state}",
            )
    if len(observations) != ASSIGNMENT_COUNT or not all(
        isinstance(value, dict) and value.get("state") == "observed" for value in observations
    ):
        return typed_observation("missing", unit=unit, reason=f"assignment {field} observations are incomplete")
    if field == "usage":
        value = sum(observation["token_count"]["value"] for observation in observations)
    else:
        value = sum(observation["value"] for observation in observations)
    return typed_observation("observed", value=value, unit=unit)


def aggregate_context_occupancy(results: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    contexts = []
    for result in results:
        usage = result.get("usage")
        if not isinstance(usage, dict) or usage.get("state") != "observed":
            state = usage.get("state") if isinstance(usage, dict) else "missing"
            return typed_observation(
                state if state in {"unsupported", "missing", "invalid"} else "missing",
                unit="tokens",
                reason="provider usage does not expose a complete context occupancy set",
            )
        contexts.append(usage["context_occupancy"])
    for state in ("invalid", "missing", "unsupported"):
        if any(context.get("state") == state for context in contexts):
            return typed_observation(
                state, unit="tokens", reason=f"one or more context occupancy values are {state}"
            )
    return typed_observation(
        "observed", value=sum(context["value"] for context in contexts), unit="tokens"
    )


def run_assignment_set(
    assignments: Sequence[Mapping[str, Any]],
    assignment_order: Sequence[str],
    width: int,
    *,
    timeout_seconds: float,
    environment: Mapping[str, str],
    corpus: Optional[Mapping[str, Any]] = None,
) -> dict[str, Any]:
    """Run six FIFO-dispatched assignments, retaining every crash and timeout (ITT)."""
    if width not in TREATMENTS:
        raise ProtocolError("assignment width must be one of 1/2/3/6")
    by_id = {assignment["id"]: assignment for assignment in assignments}
    if set(assignment_order) != set(by_id) or len(assignment_order) != ASSIGNMENT_COUNT:
        raise ProtocolError("assignment_order must be a permutation of all six assignments")
    base_env = dict(os.environ)
    base_env.update(environment)
    results: dict[str, dict[str, Any]] = {}
    active: dict[str, dict[str, Any]] = {}
    contaminated_groups: list[int] = []
    queue = list(assignment_order)
    dispatch_sequence: list[str] = []
    sampler = OwnedGroupSampler()
    user_before, system_before = _rusage_snapshot()
    wall_started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="epic-cycle-concurrency-") as temporary:
        root = Path(temporary)
        sampler.start()
        try:
            while queue or active:
                while queue and len(active) < width:
                    assignment_id = queue.pop(0)
                    assignment = by_id[assignment_id]
                    stdout_path = root / f"{len(dispatch_sequence):02d}-{assignment_id}.stdout"
                    stderr_path = root / f"{len(dispatch_sequence):02d}-{assignment_id}.stderr"
                    env = dict(base_env)
                    env.update(
                        {
                            "BARKPARK_BENCH_ASSIGNMENT_ID": assignment_id,
                            "BARKPARK_BENCH_WIDTH": str(width),
                            "BARKPARK_BENCH_SEED": str(SEED),
                        }
                    )
                    dispatched_at = time.monotonic()
                    try:
                        process, identity, pgid = launch_owned_process(
                            assignment["argv"], env=env, stdout_path=stdout_path, stderr_path=stderr_path
                        )
                    except (OSError, subprocess.SubprocessError, SafetyError) as error:
                        results[assignment_id] = {
                            "assignment_id": assignment_id,
                            "status": "launch_failure",
                            "complete": False,
                            "contradiction_unsupported": True,
                            "exit_code": None,
                            "wall_seconds": time.monotonic() - dispatched_at,
                            "wall_scope": "dispatch through launch/fence failure",
                            "reason": str(error),
                            "process_identity": None,
                            "pgid": None,
                        }
                        if corpus is not None:
                            results[assignment_id].update(
                                {
                                    "vui": typed_observation(
                                        "missing", unit="claims", reason="assignment launch failed"
                                    ),
                                    "usage": typed_observation(
                                        "missing", unit="tokens", reason="assignment launch failed"
                                    ),
                                    "attribution": assignment["attribution"],
                                }
                            )
                    else:
                        sampler.register(pgid)
                        launched_at = time.monotonic()
                        active[assignment_id] = {
                            "process": process,
                            "identity": identity,
                            "pgid": pgid,
                            "wall_started": dispatched_at,
                            "deadline": launched_at + timeout_seconds,
                            "stdout": stdout_path,
                            "stderr": stderr_path,
                        }
                    dispatch_sequence.append(assignment_id)

                now = time.monotonic()
                completed: list[str] = []
                for assignment_id, state in active.items():
                    process = state["process"]
                    returncode = process.poll()
                    timed_out = returncode is None and now >= state["deadline"]
                    if returncode is None and not timed_out:
                        continue
                    if timed_out:
                        terminate_owned_group(state["pgid"], leader=process)
                        returncode = process.returncode
                        status = "timeout"
                        group_cleanup = {
                            "status": "terminated_after_timeout",
                            "action": "SIGTERM/SIGKILL as needed",
                            "verified_disappearance": True,
                        }
                    else:
                        process.wait()
                        status = "success" if returncode == 0 else "failure"
                        group_cleanup = drain_group_after_leader_exit(state["pgid"])
                        if group_cleanup["status"] == "contaminated":
                            contaminated_groups.append(state["pgid"])
                            status = "process_group_contaminated"
                    stdout = state["stdout"].read_text(encoding="utf-8", errors="replace")
                    stderr = state["stderr"].read_text(encoding="utf-8", errors="replace")
                    retrieval_evaluation = None
                    if corpus is None:
                        complete, contradiction, evaluation_reason = _parse_assignment_evaluation(stdout)
                    else:
                        retrieval_evaluation = parse_retrieval_evaluation(
                            stdout,
                            retrieval_record(corpus, assignment_id),
                            by_id[assignment_id]["attribution"],
                        )
                        complete = retrieval_evaluation["complete"]
                        contradiction = retrieval_evaluation["contradiction_unsupported"]
                        evaluation_reason = retrieval_evaluation["reason"]
                    if status != "success":
                        complete = False
                    if status == "process_group_contaminated":
                        contradiction = True
                        evaluation_reason = (
                            "owned process group retained live members after its leader exited; "
                            "the group was terminated and disappearance verified"
                        )
                    if contradiction is None:
                        contradiction = True
                    assignment_result = {
                        "assignment_id": assignment_id,
                        "status": status,
                        "complete": bool(complete),
                        "contradiction_unsupported": bool(contradiction),
                        "exit_code": returncode,
                        "wall_seconds": time.monotonic() - state["wall_started"],
                        "wall_scope": "dispatch through launch/fence and terminal observation",
                        "reason": evaluation_reason,
                        "process_identity": asdict(state["identity"]),
                        "pgid": state["pgid"],
                        "process_group_cleanup": group_cleanup,
                        "stdout_tail": (
                            stdout[-2000:]
                            if corpus is None
                            else "[REDACTED: retrieval evaluation consumed]"
                        ),
                        "stderr_tail": (
                            stderr[-2000:]
                            if corpus is None
                            else "[REDACTED: retrieval stderr withheld]"
                        ),
                    }
                    if retrieval_evaluation is not None:
                        assignment_result.update(
                            {
                                "vui": retrieval_evaluation["vui"],
                                "usage": retrieval_evaluation["usage"],
                                "attribution": retrieval_evaluation["attribution"],
                            }
                        )
                    results[assignment_id] = assignment_result
                    completed.append(assignment_id)
                for assignment_id in completed:
                    active.pop(assignment_id)
                if active and not completed:
                    time.sleep(0.01)
        finally:
            for state in active.values():
                terminate_owned_group(state["pgid"], leader=state["process"])
            sampler.stop()
    wall_seconds = time.monotonic() - wall_started
    user_after, system_after = _rusage_snapshot()
    user_seconds = max(0.0, user_after - user_before)
    system_seconds = max(0.0, system_after - system_before)
    cpu_percent = (user_seconds + system_seconds) / wall_seconds * 100.0 if wall_seconds > 0 else None
    ordered_results = [results[assignment_id] for assignment_id in assignment_order]
    if corpus is not None:
        reject_duplicate_usage_identities(ordered_results)
    metrics = {
        "wall": measured(wall_seconds, "seconds", "time.monotonic", "six-assignment treatment trial"),
        "user": measured(user_seconds, "seconds", "resource.getrusage(RUSAGE_CHILDREN)", "owned child process groups"),
        "system": measured(system_seconds, "seconds", "resource.getrusage(RUSAGE_CHILDREN)", "owned child process groups"),
        "rss": (
            measured(sampler.peak_rss_bytes, "bytes", "owned process-group sampler", "sum of live owned groups, peak")
            if sampler.peak_rss_bytes is not None
            else null_metric("bytes", "owned process-group sampler", "sum of live owned groups, peak", "no RSS sample observed")
        ),
        "cpu": (
            measured(cpu_percent, "percent_of_one_cpu", "(user+system)/wall", "owned child process groups")
            if cpu_percent is not None
            else null_metric("percent_of_one_cpu", "(user+system)/wall", "owned child process groups", "zero wall interval")
        ),
        "sampled_cpu": (
            measured(sampler.peak_cpu_percent, "percent_of_one_cpu", "owned process-group sampler", "sum of live owned groups, peak")
            if sampler.peak_cpu_percent is not None
            else unsupported_metric(
                "percent_of_one_cpu",
                "owned process-group sampler",
                "sum of live owned groups, peak",
                "platform sampler did not expose instantaneous CPU",
            )
        ),
    }
    if corpus is None:
        metrics.update(
            {
                "token_cost": unsupported_metric(
                    "tokens",
                    "assignment evaluation contract",
                    "six-assignment treatment trial",
                    "the narrow assignment evaluation payload does not expose token accounting",
                ),
                "context_cost": unsupported_metric(
                    "tokens",
                    "assignment evaluation contract",
                    "six-assignment treatment trial",
                    "the narrow assignment evaluation payload does not expose context accounting",
                ),
                "verified_unique_information": unsupported_metric(
                    "items",
                    "assignment evaluation contract",
                    "six-assignment treatment trial",
                    "no preregistered unique-information verifier is part of this benchmark",
                ),
            }
        )
    else:
        metrics.update(
            {
                "token_cost": aggregate_typed_observations(ordered_results, "usage", "tokens"),
                "context_cost": aggregate_context_occupancy(ordered_results),
                "verified_unique_information": aggregate_typed_observations(
                    ordered_results, "vui", "claims"
                ),
            }
        )
    return {
        "assignment_results": ordered_results,
        "dispatch_sequence": dispatch_sequence,
        "process_group_contamination": contaminated_groups,
        "metrics": metrics,
        "sampler": {"sample_count": sampler.sample_count, "errors": sampler.errors},
    }


def default_treatment_runner(
    manifest: Mapping[str, Any], trial: Mapping[str, Any], sensitivity_of: Optional[str]
) -> dict[str, Any]:
    env = dict(os.environ)
    env.update(manifest["environment"])
    env.update(
        {
            "BARKPARK_BENCH_TRIAL_ID": trial["trial_id"],
            "BARKPARK_BENCH_LOOK": str(trial["look"]),
            "BARKPARK_BENCH_WIDTH": str(trial["width"]),
            "BARKPARK_BENCH_SENSITIVITY_OF": sensitivity_of or "",
        }
    )
    retrieval = is_retrieval_schema(manifest["schema_version"])
    reset = run_control_command(
        manifest["cold_reset_argv"],
        env,
        manifest["timeout_seconds"],
        "cold reset",
        semantic_state="cold" if retrieval else None,
        corpus=manifest.get("corpus"),
    )
    prime = run_control_command(
        manifest["warm_prime_argv"],
        env,
        manifest["timeout_seconds"],
        "warm prime",
        semantic_state="warm" if retrieval else None,
        corpus=manifest.get("corpus"),
    )
    measured_work = run_assignment_set(
        manifest["assignments"],
        trial["assignment_order"],
        trial["width"],
        timeout_seconds=manifest["timeout_seconds"],
        environment=env,
        corpus=manifest.get("corpus"),
    )
    if retrieval:
        return {"cold_reset": reset, "warm_prime": prime, **measured_work}
    return {
        "cold_reset": {
            **reset,
            "semantic_verification": unsupported_metric(
                "boolean",
                "declared cold_reset_argv",
                "pre-treatment control",
                "the runner verifies command success, not that the command produced a cold state",
            ),
        },
        "warm_prime": {
            **prime,
            "semantic_verification": unsupported_metric(
                "boolean",
                "declared warm_prime_argv",
                "pre-treatment control",
                "the runner verifies command success, not that the command produced a warm state",
            ),
        },
        **measured_work,
    }


def _trial_rates(trial: Mapping[str, Any]) -> dict[str, float]:
    results = trial.get("assignment_results", [])
    count = len(results)
    if count != ASSIGNMENT_COUNT:
        return {"completeness_pp": 0.0, "contradiction_unsupported_pp": 100.0, "failure_timeout_pp": 100.0}
    complete = sum(result.get("complete") is True for result in results)
    contradiction = sum(result.get("contradiction_unsupported") is True for result in results)
    failures = sum(result.get("status") != "success" for result in results)
    return {
        "completeness_pp": complete / count * 100.0,
        "contradiction_unsupported_pp": contradiction / count * 100.0,
        "failure_timeout_pp": failures / count * 100.0,
    }


def aggregate_widths(trials: Sequence[Mapping[str, Any]]) -> dict[int, dict[str, float]]:
    grouped: dict[int, list[Mapping[str, Any]]] = {width: [] for width in TREATMENTS}
    for trial in trials:
        width = trial.get("width")
        if width in grouped:
            grouped[width].append(trial)
    aggregates: dict[int, dict[str, float]] = {}
    for width, items in grouped.items():
        rates = [_trial_rates(item) for item in items]
        if not rates:
            aggregates[width] = {
                "trial_count": 0.0,
                "completeness_pp": 0.0,
                "contradiction_unsupported_pp": 100.0,
                "failure_timeout_pp": 100.0,
            }
            continue
        aggregates[width] = {
            "trial_count": float(len(items)),
            **{
                key: sum(rate[key] for rate in rates) / len(rates)
                for key in ("completeness_pp", "contradiction_unsupported_pp", "failure_timeout_pp")
            },
        }
    return aggregates


def select_width_all_pairs(aggregates: Mapping[int, Mapping[str, float]]) -> dict[str, Any]:
    """Select the highest width non-inferior to every peer at all frozen margins."""
    comparisons: list[dict[str, Any]] = []
    eligible: list[int] = []
    for candidate in TREATMENTS:
        candidate_values = aggregates.get(candidate)
        candidate_ok = bool(candidate_values and candidate_values.get("trial_count", 0) > 0)
        for peer in TREATMENTS:
            if peer == candidate:
                continue
            peer_values = aggregates.get(peer)
            if not candidate_values or not peer_values or peer_values.get("trial_count", 0) <= 0:
                passed = False
                reasons = ["missing balanced evidence"]
            else:
                reasons = []
                if candidate_values["completeness_pp"] < peer_values["completeness_pp"] - COMPLETENESS_MARGIN_PP:
                    reasons.append("completeness worse by more than 5pp")
                if candidate_values["contradiction_unsupported_pp"] > peer_values["contradiction_unsupported_pp"] + CONTRADICTION_MARGIN_PP:
                    reasons.append("contradiction/unsupported worse by more than 2pp")
                if candidate_values["failure_timeout_pp"] > peer_values["failure_timeout_pp"] + FAILURE_MARGIN_PP:
                    reasons.append("failure/timeout worse by more than 5pp")
                passed = not reasons
            comparisons.append({"candidate": candidate, "peer": peer, "passed": passed, "reasons": reasons})
            candidate_ok = candidate_ok and passed
        if candidate_ok:
            eligible.append(candidate)
    return {
        "selected_width": max(eligible) if eligible else None,
        "eligible_widths": eligible,
        "comparisons": comparisons,
        "margins_pp": {
            "completeness": -COMPLETENESS_MARGIN_PP,
            "contradiction_unsupported": CONTRADICTION_MARGIN_PP,
            "failure_timeout": FAILURE_MARGIN_PP,
        },
        "interpretation": (
            "highest all-pairs-eligible width under preregistered quality margins; "
            "not a statistically-fastest or knee estimate"
        ),
        "statistically_fastest_width": unsupported_metric(
            "concurrency_width",
            "fixed all-pairs quality-margin rule",
            "selection report",
            "no preregistered runtime hypothesis test or sufficient repeated runtime evidence",
        ),
        "knee_width": unsupported_metric(
            "concurrency_width",
            "fixed all-pairs quality-margin rule",
            "selection report",
            "no preregistered knee estimator or sufficient repeated runtime evidence",
        ),
    }


def contamination_scope() -> dict[str, Any]:
    """State exactly what the contamination flag can and cannot establish."""
    return {
        "monitored": [
            "declared tmux pane pid/start identity changes",
            "owned process-group sampler errors",
        ],
        "not_monitored": {
            "host_load1_drift": unsupported_metric(
                "load_average",
                "host admission snapshot only",
                "within-treatment contamination",
                "load1 is checked at admission but not sampled before and after each treatment",
            ),
            "memory_available_drift": unsupported_metric(
                "bytes",
                "host admission snapshot only",
                "within-treatment contamination",
                "available memory is checked at admission but not sampled before and after each treatment",
            ),
        },
        "interpretation": "a clean contamination flag does not rule out host-load or available-memory drift",
    }


def trials_for_analysis(originals: Sequence[Mapping[str, Any]], reruns: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """Use clean reruns for sensitivity while preserving contaminated originals in output."""
    clean_reruns = {
        rerun.get("sensitivity_of"): rerun
        for rerun in reruns
        if rerun.get("sensitivity_of") and not rerun.get("contaminated", True)
    }
    return [clean_reruns.get(original.get("trial_id"), original) for original in originals]


def build_epicfleet_attribution(
    manifest: Mapping[str, Any],
    originals: Sequence[Mapping[str, Any]],
    reruns: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    assignments = [assignment["attribution"] for assignment in manifest["assignments"]]
    corpus = manifest["corpus"]
    trials = []
    for trial in [*originals, *reruns]:
        rows = [
            {
                "assignment_id": result["assignment_id"],
                "attribution": result.get("attribution"),
                "usage": result.get("usage"),
                "vui": result.get("vui"),
            }
            for result in trial.get("assignment_results", [])
        ]
        trials.append(
            {
                "trial_id": trial["trial_id"],
                "sensitivity_of": trial.get("sensitivity_of"),
                "assignments": rows,
            }
        )
    return {
        "schema_version": (
            RETRIEVAL_ATTRIBUTION_SCHEMA_VERSION_V3
            if manifest["schema_version"] == RETRIEVAL_SCHEMA_VERSION_V3
            else RETRIEVAL_ATTRIBUTION_SCHEMA_VERSION
        ),
        "epic_id": assignments[0]["epic_id"],
        "wave_id": assignments[0]["wave_id"],
        "corpus": {
            key: corpus[key]
            for key in (
                "sha256",
                "repo_commit",
                "schema_version",
                "unit_ids",
                "claim_domain",
                "claim_domain_digest",
            )
        },
        "assignments": assignments,
        "trials": trials,
    }


def execute_protocol(
    manifest: Mapping[str, Any],
    admission: AdmissionDecision,
    *,
    treatment_runner: Callable[[Mapping[str, Any], Mapping[str, Any], Optional[str]], dict[str, Any]] = default_treatment_runner,
    snapshotter: Callable[[Sequence[str]], PaneSnapshot] = capture_pane_snapshot,
) -> dict[str, Any]:
    normalized = validate_manifest(manifest)
    if not admission.admitted:
        raise SafetyError("host admission denied: " + "; ".join(admission.reasons))
    if admission.signals.pane != normalized["primary_pane"] or admission.signals.pane_identity is None:
        raise SafetyError("admission identity does not belong to the manifest primary pane")
    expected_primary = admission.signals.pane_identity
    plan = plan_artifact(normalized)
    originals: list[dict[str, Any]] = []
    for spec in plan["schedule"]:
        before = snapshotter(normalized["tmux_panes"])
        assert_primary_fence(before, normalized["primary_pane"], expected_primary)
        payload = treatment_runner(normalized, spec, None)
        after = snapshotter(normalized["tmux_panes"])
        assert_primary_fence(after, normalized["primary_pane"], expected_primary)
        reasons = contamination_reasons(before, after, normalized["primary_pane"])
        reasons.extend(execution_contamination_reasons(payload))
        originals.append(
            {
                **spec,
                **payload,
                "contaminated": bool(reasons),
                "contamination_reasons": reasons,
                "pane_snapshot_before": snapshot_json(before),
                "pane_snapshot_after": snapshot_json(after),
            }
        )

    reruns: list[dict[str, Any]] = []
    for original in originals:
        if not original["contaminated"]:
            continue
        spec = {key: original[key] for key in ("trial_id", "look", "williams_row", "position", "width", "assignment_order", "cold_reset", "warm_prime")}
        before = snapshotter(normalized["tmux_panes"])
        assert_primary_fence(before, normalized["primary_pane"], expected_primary)
        payload = treatment_runner(normalized, spec, original["trial_id"])
        after = snapshotter(normalized["tmux_panes"])
        assert_primary_fence(after, normalized["primary_pane"], expected_primary)
        reasons = contamination_reasons(before, after, normalized["primary_pane"])
        reasons.extend(execution_contamination_reasons(payload))
        reruns.append(
            {
                **spec,
                **payload,
                "trial_id": original["trial_id"] + "-sensitivity",
                "sensitivity_of": original["trial_id"],
                "contaminated": bool(reasons),
                "contamination_reasons": reasons,
                "pane_snapshot_before": snapshot_json(before),
                "pane_snapshot_after": snapshot_json(after),
            }
        )

    analyzed = trials_for_analysis(originals, reruns)
    fixed_look_results = []
    for look in FIXED_LOOKS:
        through_look = [trial for trial in analyzed if trial["look"] <= look]
        aggregates = aggregate_widths(through_look)
        fixed_look_results.append(
            {
                "look": look,
                "trials_per_width": look,
                "aggregates": {str(width): values for width, values in aggregates.items()},
                "selection": select_width_all_pairs(aggregates),
                "decision_binding": look == FIXED_LOOKS[-1],
            }
        )
    result = {
        **plan,
        "admission": admission_json(admission),
        "original_trials": originals,
        "sensitivity_reruns": reruns,
        "analysis_policy": "clean sensitivity rerun replaces contaminated original; original is retained",
        "contamination_scope": contamination_scope(),
        "fixed_look_results": fixed_look_results,
        "final_selection": fixed_look_results[-1]["selection"],
    }
    if is_retrieval_schema(normalized["schema_version"]):
        result["epicfleet_attribution"] = build_epicfleet_attribution(
            normalized, originals, reruns
        )
        result["epicfleet_attribution_digest"] = digest_json(
            result["epicfleet_attribution"]
        )
    return result


def snapshot_json(snapshot: PaneSnapshot) -> dict[str, Any]:
    return {
        "identities": {pane: asdict(identity) for pane, identity in sorted(snapshot.identities.items())},
        "missing": list(snapshot.missing),
    }


def admission_json(decision: AdmissionDecision) -> dict[str, Any]:
    return {
        "admitted": decision.admitted,
        "heavy_capacity": decision.heavy_capacity,
        "reasons": list(decision.reasons),
        "signals": {
            **asdict(decision.signals),
            "pane_identity": asdict(decision.signals.pane_identity) if decision.signals.pane_identity else None,
        },
    }


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    plan = subparsers.add_parser("plan", help="write the frozen schedule without running work")
    plan.add_argument("--config", type=Path, required=True)
    plan.add_argument("--output", type=Path, required=True)
    for name in ("run", "replay"):
        command = subparsers.add_parser(name, help=f"{name} the admitted benchmark")
        command.add_argument("--config", type=Path, required=True)
        command.add_argument("--output", type=Path, required=True)
        command.add_argument("--execute-heavy", action="store_true", help="required acknowledgement")
        command.add_argument("--heavy-capacity", type=int, choices=(1, 2), default=DEFAULT_HEAVY_CAPACITY)
        command.add_argument("--allow-capacity-two", action="store_true")
        if name == "replay":
            command.add_argument("--artifact", type=Path, required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        manifest = load_manifest(args.config)
        if args.command == "plan":
            write_json(args.output, plan_artifact(manifest))
            print(f"wrote frozen benchmark plan: {args.output}")
            return 0
        if not args.execute_heavy:
            raise SafetyError("measured work requires --execute-heavy")
        if args.command == "replay":
            with args.artifact.open(encoding="utf-8") as handle:
                replay = json.load(handle)
            if not isinstance(replay, dict):
                raise ProtocolError("replay artifact root must be an object")
            verify_replay(replay, manifest)
        signals = capture_host_signals(manifest["primary_pane"])
        admission = admit_heavy_run(
            signals,
            args.heavy_capacity,
            capacity_two_explicit=args.allow_capacity_two,
        )
        if not admission.admitted:
            write_json(args.output, {"schema_version": SCHEMA_VERSION, "admission": admission_json(admission)})
            raise SafetyError("host admission denied: " + "; ".join(admission.reasons))
        with HeavyCapacityLease(admission.heavy_capacity) as lease:
            result = execute_protocol(manifest, admission)
            result["admission"]["heavy_slot"] = lease.slot_index
        write_json(args.output, result)
        print(f"wrote benchmark result: {args.output}")
        return 0
    except (OSError, json.JSONDecodeError, ProtocolError, SafetyError, subprocess.SubprocessError) as error:
        print(f"benchmark error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
