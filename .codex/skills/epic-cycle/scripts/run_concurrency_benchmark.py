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
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Optional, Sequence


SCHEMA_VERSION = "epic-cycle-concurrency-v1"
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


def validate_manifest(manifest: Mapping[str, Any]) -> dict[str, Any]:
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
        "schema_version": SCHEMA_VERSION,
        "seed": SEED,
        "treatments": list(TREATMENTS),
        "assignments_per_trial": ASSIGNMENT_COUNT,
        "williams_rows": [list(row) for row in WILLIAMS_ROWS],
        "fixed_looks": list(FIXED_LOOKS),
        "schedule": build_schedule(ids),
        "manifest_digest": digest_json(normalized),
    }
    frozen["plan_digest"] = digest_json(frozen)
    return frozen


def verify_replay(plan: Mapping[str, Any], manifest: Mapping[str, Any]) -> None:
    expected = plan_artifact(manifest)
    if plan.get("schema_version") != SCHEMA_VERSION:
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
    return GroupSample(
        pgid,
        tuple(sorted(pids)),
        user_ticks / clock_ticks,
        system_ticks / clock_ticks,
        rss_pages * page_size,
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
        return GroupSample(
            pgid,
            tuple(sorted(pids)),
            None,
            None,
            rss_kib * 1024,
            cpu_percent,
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


def launch_owned_process(
    argv: Sequence[str],
    *,
    env: Mapping[str, str],
    stdout_path: Path,
    stderr_path: Path,
) -> tuple[subprocess.Popen[str], ProcessIdentity, int]:
    stdout_handle = stdout_path.open("w", encoding="utf-8")
    stderr_handle = stderr_path.open("w", encoding="utf-8")
    try:
        process = subprocess.Popen(
            list(argv),
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
    identity = read_process_identity(process.pid)
    pgid = os.getpgid(process.pid)
    if pgid != process.pid:
        terminate_owned_group(pgid)
        raise SafetyError("child did not become leader of its owned process group")
    if not identity_is_live(identity):
        terminate_owned_group(pgid)
        raise SafetyError("child process identity could not be fenced after launch")
    return process, identity, pgid


def terminate_owned_group(pgid: int, grace_seconds: float = 1.0) -> None:
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
    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            # No signalable live member remains for this uid.
            return
        time.sleep(0.02)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        try:
            os.kill(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run_control_command(argv: Sequence[str], env: Mapping[str, str], timeout_seconds: float, label: str) -> dict[str, Any]:
    started = time.monotonic()
    try:
        result = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            env=dict(env),
            timeout=timeout_seconds,
            check=False,
            start_new_session=True,
        )
    except subprocess.TimeoutExpired as error:
        raise SafetyError(f"{label} timed out after {timeout_seconds}s") from error
    if result.returncode != 0:
        raise SafetyError(f"{label} failed with exit {result.returncode}: {result.stderr[-500:]}")
    return {"status": "passed", "wall_seconds": time.monotonic() - started}


def run_assignment_set(
    assignments: Sequence[Mapping[str, Any]],
    assignment_order: Sequence[str],
    width: int,
    *,
    timeout_seconds: float,
    environment: Mapping[str, str],
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
                            "wall_seconds": 0.0,
                            "reason": str(error),
                            "process_identity": None,
                            "pgid": None,
                        }
                    else:
                        sampler.register(pgid)
                        active[assignment_id] = {
                            "process": process,
                            "identity": identity,
                            "pgid": pgid,
                            "started": dispatched_at,
                            "deadline": dispatched_at + timeout_seconds,
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
                        terminate_owned_group(state["pgid"])
                        returncode = process.wait(timeout=2.0)
                        status = "timeout"
                    else:
                        process.wait()
                        status = "success" if returncode == 0 else "failure"
                    stdout = state["stdout"].read_text(encoding="utf-8", errors="replace")
                    stderr = state["stderr"].read_text(encoding="utf-8", errors="replace")
                    complete, contradiction, evaluation_reason = _parse_assignment_evaluation(stdout)
                    if status != "success":
                        complete = False
                    if contradiction is None:
                        contradiction = True
                    results[assignment_id] = {
                        "assignment_id": assignment_id,
                        "status": status,
                        "complete": bool(complete),
                        "contradiction_unsupported": bool(contradiction),
                        "exit_code": returncode,
                        "wall_seconds": time.monotonic() - state["started"],
                        "reason": evaluation_reason,
                        "process_identity": asdict(state["identity"]),
                        "pgid": state["pgid"],
                        "stdout_tail": stdout[-2000:],
                        "stderr_tail": stderr[-2000:],
                    }
                    completed.append(assignment_id)
                for assignment_id in completed:
                    active.pop(assignment_id)
                if active and not completed:
                    time.sleep(0.01)
        finally:
            for state in active.values():
                terminate_owned_group(state["pgid"])
            sampler.stop()
    wall_seconds = time.monotonic() - wall_started
    user_after, system_after = _rusage_snapshot()
    user_seconds = max(0.0, user_after - user_before)
    system_seconds = max(0.0, system_after - system_before)
    cpu_percent = (user_seconds + system_seconds) / wall_seconds * 100.0 if wall_seconds > 0 else None
    ordered_results = [results[assignment_id] for assignment_id in assignment_order]
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
    return {
        "assignment_results": ordered_results,
        "dispatch_sequence": dispatch_sequence,
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
    reset = run_control_command(manifest["cold_reset_argv"], env, manifest["timeout_seconds"], "cold reset")
    prime = run_control_command(manifest["warm_prime_argv"], env, manifest["timeout_seconds"], "warm prime")
    measured_work = run_assignment_set(
        manifest["assignments"],
        trial["assignment_order"],
        trial["width"],
        timeout_seconds=manifest["timeout_seconds"],
        environment=env,
    )
    return {"cold_reset": reset, "warm_prime": prime, **measured_work}


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
    }


def trials_for_analysis(originals: Sequence[Mapping[str, Any]], reruns: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """Use clean reruns for sensitivity while preserving contaminated originals in output."""
    clean_reruns = {
        rerun.get("sensitivity_of"): rerun
        for rerun in reruns
        if rerun.get("sensitivity_of") and not rerun.get("contaminated", True)
    }
    return [clean_reruns.get(original.get("trial_id"), original) for original in originals]


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
    plan = plan_artifact(normalized)
    originals: list[dict[str, Any]] = []
    for spec in plan["schedule"]:
        before = snapshotter(normalized["tmux_panes"])
        payload = treatment_runner(normalized, spec, None)
        after = snapshotter(normalized["tmux_panes"])
        reasons = contamination_reasons(before, after, normalized["primary_pane"])
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
        payload = treatment_runner(normalized, spec, original["trial_id"])
        after = snapshotter(normalized["tmux_panes"])
        reasons = contamination_reasons(before, after, normalized["primary_pane"])
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
    return {
        **plan,
        "admission": admission_json(admission),
        "original_trials": originals,
        "sensitivity_reruns": reruns,
        "analysis_policy": "clean sensitivity rerun replaces contaminated original; original is retained",
        "fixed_look_results": fixed_look_results,
        "final_selection": fixed_look_results[-1]["selection"],
    }


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
        result = execute_protocol(manifest, admission)
        write_json(args.output, result)
        print(f"wrote benchmark result: {args.output}")
        return 0
    except (OSError, json.JSONDecodeError, ProtocolError, SafetyError, subprocess.SubprocessError) as error:
        print(f"benchmark error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
