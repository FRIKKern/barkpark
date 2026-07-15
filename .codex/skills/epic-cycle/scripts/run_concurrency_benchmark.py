#!/usr/bin/env python3
"""Deterministic, fail-closed runner for Epic Cycle concurrency benchmarks.

The runner intentionally owns only commands launched through this file.  It does
not claim to intercept arbitrary worker, build, or test processes.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import platform
import random
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Optional


SCHEMA_VERSION = "1.0"
SEED = 20260715
WIDTHS = (1, 2, 3, 6)
ASSIGNMENTS_PER_TREATMENT = 6
WILLIAMS_ROWS = (
    (1, 2, 6, 3),
    (2, 3, 1, 6),
    (3, 6, 2, 1),
    (6, 1, 3, 2),
)
FIXED_LOOKS = (4, 8, 12, 16)
DEFAULT_CYCLES = 4
DEFAULT_HEAVY_CAPACITY = 1
METRIC_STATES = frozenset({"observed", "unsupported", "missing", "invalid"})
REQUIRED_HOST_METRICS = (
    "cpu_count",
    "load_1m",
    "memory_total_bytes",
    "memory_available_bytes",
    "swap_total_bytes",
    "swap_used_bytes",
)
REGRESSION_LIMITS = {
    "completeness_pp": -5,
    "contradiction_or_unsupported_pp": 2,
    "failure_or_timeout_pp": 5,
}


class ContractError(ValueError):
    """The frozen benchmark contract was not satisfied."""


class SafetyDenied(RuntimeError):
    """The host or process identity could not be admitted safely."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def metric(
    state: str,
    value: Any = None,
    *,
    unit: Optional[str] = None,
    source: Optional[str] = None,
    detail: Optional[str] = None,
) -> dict[str, Any]:
    if state not in METRIC_STATES:
        raise ContractError(f"invalid metric state: {state}")
    if state == "observed" and value is None:
        raise ContractError("observed metric requires a value")
    if state != "observed" and value is not None:
        raise ContractError(f"{state} metric value must be null")
    return {"state": state, "value": value, "unit": unit, "source": source, "detail": detail}


def observed(value: Any, unit: Optional[str], source: str) -> dict[str, Any]:
    return metric("observed", value, unit=unit, source=source)


def unknown(state: str, unit: Optional[str], source: str, detail: str) -> dict[str, Any]:
    return metric(state, None, unit=unit, source=source, detail=detail)


@dataclass(frozen=True)
class ProcessIdentity:
    platform: str
    pid: int
    pgid: int
    start_marker: str
    boot_marker: Optional[str]


def _linux_stat(pid: int, proc_root: Path = Path("/proc")) -> Optional[list[str]]:
    try:
        raw = (proc_root / str(pid) / "stat").read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return None
    close = raw.rfind(")")
    if close < 0:
        return None
    return raw[close + 2 :].split()


def capture_process_identity(
    pid: int,
    *,
    system: Optional[str] = None,
    proc_root: Path = Path("/proc"),
) -> Optional[ProcessIdentity]:
    system = (system or platform.system()).lower()
    if system == "linux":
        fields = _linux_stat(pid, proc_root)
        if not fields or len(fields) <= 19:
            return None
        try:
            pgid = int(fields[2])
            start_marker = fields[19]
        except (ValueError, IndexError):
            return None
        try:
            boot_marker = (proc_root / "sys/kernel/random/boot_id").read_text(encoding="utf-8").strip()
        except (FileNotFoundError, PermissionError):
            return None
        if not boot_marker:
            return None
        return ProcessIdentity("linux", pid, pgid, start_marker, boot_marker)
    if system == "darwin":
        result = subprocess.run(
            ["ps", "-o", "pgid=", "-o", "lstart=", "-p", str(pid)],
            text=True,
            capture_output=True,
            check=False,
        )
        parts = result.stdout.strip().split()
        if result.returncode or len(parts) < 6:
            return None
        try:
            pgid = int(parts[0])
        except ValueError:
            return None
        return ProcessIdentity("darwin", pid, pgid, " ".join(parts[1:]), None)
    return None


def identity_matches(identity: ProcessIdentity, *, proc_root: Path = Path("/proc")) -> bool:
    return capture_process_identity(identity.pid, system=identity.platform, proc_root=proc_root) == identity


def _parse_meminfo(proc_root: Path = Path("/proc")) -> dict[str, int]:
    values: dict[str, int] = {}
    for line in (proc_root / "meminfo").read_text(encoding="utf-8").splitlines():
        match = re.match(r"([^:]+):\s+(\d+)\s+kB", line)
        if match:
            values[match.group(1)] = int(match.group(2)) * 1024
    return values


def _darwin_int(command: list[str]) -> int:
    return int(subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip())


class SystemSampler:
    def __init__(self, *, system: Optional[str] = None, proc_root: Path = Path("/proc")) -> None:
        self.system = (system or platform.system()).lower()
        self.proc_root = proc_root

    def host(self) -> dict[str, Any]:
        source = self.system
        metrics: dict[str, Any] = {
            "cpu_count": observed(os.cpu_count(), "count", source) if os.cpu_count() else unknown("missing", "count", source, "os.cpu_count returned null"),
            "load_1m": observed(os.getloadavg()[0], "load", source),
            "thermal_state": unknown("unsupported", "state", source, "portable thermal state is unavailable"),
        }
        try:
            if self.system == "linux":
                mem = _parse_meminfo(self.proc_root)
                total = mem["MemTotal"]
                available = mem.get("MemAvailable", mem.get("MemFree"))
                swap_total = mem["SwapTotal"]
                swap_used = swap_total - mem["SwapFree"]
            elif self.system == "darwin":
                total = _darwin_int(["sysctl", "-n", "hw.memsize"])
                vm = subprocess.run(["vm_stat"], check=True, text=True, capture_output=True).stdout
                page_match = re.search(r"page size of (\d+) bytes", vm)
                if not page_match:
                    raise ValueError("vm_stat page size missing")
                page_size = int(page_match.group(1))
                pages = {name: int(value) for name, value in re.findall(r"Pages ([^:]+):\s+(\d+)\.", vm)}
                available = page_size * sum(pages.get(name, 0) for name in ("free", "inactive", "speculative"))
                swap = subprocess.run(["sysctl", "-n", "vm.swapusage"], check=True, text=True, capture_output=True).stdout
                numbers = re.findall(r"(?:total|used) = ([0-9.]+)([MG])", swap)
                if len(numbers) < 2:
                    raise ValueError("vm.swapusage fields missing")
                scale = lambda pair: int(float(pair[0]) * (1024**2 if pair[1] == "M" else 1024**3))
                swap_total, swap_used = scale(numbers[0]), scale(numbers[1])
            else:
                raise NotImplementedError(f"unsupported platform {self.system}")
            if available is None:
                raise KeyError("memory available")
            metrics.update(
                {
                    "memory_total_bytes": observed(total, "bytes", source),
                    "memory_available_bytes": observed(available, "bytes", source),
                    "swap_total_bytes": observed(swap_total, "bytes", source),
                    "swap_used_bytes": observed(swap_used, "bytes", source),
                }
            )
        except NotImplementedError as exc:
            for name in REQUIRED_HOST_METRICS[2:]:
                metrics[name] = unknown("unsupported", "bytes", source, str(exc))
        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
            for name in REQUIRED_HOST_METRICS[2:]:
                metrics[name] = unknown("invalid", "bytes", source, str(exc))
        return {"captured_at": utc_now(), "platform": self.system, "metrics": metrics}

    def process_group(self, identity: ProcessIdentity) -> dict[str, Any]:
        source = f"{identity.platform}:pgid:{identity.pgid}"
        if not identity_matches(identity, proc_root=self.proc_root):
            return {
                "identity_valid": False,
                "cpu_seconds": unknown("invalid", "seconds", source, "root process identity changed"),
                "rss_bytes": unknown("invalid", "bytes", source, "root process identity changed"),
                "member_count": unknown("invalid", "count", source, "root process identity changed"),
            }
        try:
            if identity.platform == "linux":
                ticks = os.sysconf("SC_CLK_TCK")
                page_size = os.sysconf("SC_PAGE_SIZE")
                cpu_ticks = 0
                rss_pages = 0
                members = 0
                for entry in self.proc_root.iterdir():
                    if not entry.name.isdigit():
                        continue
                    fields = _linux_stat(int(entry.name), self.proc_root)
                    if not fields or len(fields) <= 21:
                        continue
                    try:
                        if int(fields[2]) != identity.pgid:
                            continue
                        cpu_ticks += int(fields[11]) + int(fields[12])
                        rss_pages += max(0, int(fields[21]))
                        members += 1
                    except ValueError:
                        continue
                return {
                    "identity_valid": True,
                    "cpu_seconds": observed(cpu_ticks / ticks, "seconds", source),
                    "rss_bytes": observed(rss_pages * page_size, "bytes", source),
                    "member_count": observed(members, "count", source),
                }
            if identity.platform == "darwin":
                result = subprocess.run(["ps", "-axo", "pgid=,rss="], check=True, text=True, capture_output=True)
                rows = [line.split() for line in result.stdout.splitlines()]
                rss_kib = sum(int(row[1]) for row in rows if len(row) == 2 and int(row[0]) == identity.pgid)
                members = sum(1 for row in rows if len(row) == 2 and int(row[0]) == identity.pgid)
                return {
                    "identity_valid": True,
                    "cpu_seconds": unknown("unsupported", "seconds", source, "portable Darwin group CPU unavailable"),
                    "rss_bytes": observed(rss_kib * 1024, "bytes", source),
                    "member_count": observed(members, "count", source),
                }
        except (OSError, subprocess.SubprocessError, ValueError) as exc:
            return {
                "identity_valid": True,
                "cpu_seconds": unknown("invalid", "seconds", source, str(exc)),
                "rss_bytes": unknown("invalid", "bytes", source, str(exc)),
                "member_count": unknown("invalid", "count", source, str(exc)),
            }
        return {
            "identity_valid": False,
            "cpu_seconds": unknown("unsupported", "seconds", source, "unsupported platform"),
            "rss_bytes": unknown("unsupported", "bytes", source, "unsupported platform"),
            "member_count": unknown("unsupported", "count", source, "unsupported platform"),
        }


def admission_decision(
    snapshot: dict[str, Any],
    *,
    max_load_per_cpu: float = 0.90,
    min_memory_available_ratio: float = 0.10,
    max_swap_used_ratio: float = 0.25,
) -> dict[str, Any]:
    metrics = snapshot.get("metrics") or {}
    reasons = []
    for name in REQUIRED_HOST_METRICS:
        item = metrics.get(name)
        if not isinstance(item, dict) or item.get("state") != "observed" or item.get("value") is None:
            reasons.append(f"required_metric_{name}_{item.get('state') if isinstance(item, dict) else 'missing'}")
    if reasons:
        return {"admitted": False, "reasons": reasons, "snapshot": snapshot}
    cpu_count = float(metrics["cpu_count"]["value"])
    total = float(metrics["memory_total_bytes"]["value"])
    available = float(metrics["memory_available_bytes"]["value"])
    swap_total = float(metrics["swap_total_bytes"]["value"])
    swap_used = float(metrics["swap_used_bytes"]["value"])
    if cpu_count <= 0 or total <= 0 or swap_total < 0:
        reasons.append("invalid_safety_denominator")
    else:
        if float(metrics["load_1m"]["value"]) / cpu_count > max_load_per_cpu:
            reasons.append("host_load_high")
        if available / total < min_memory_available_ratio:
            reasons.append("memory_available_low")
        if swap_total and swap_used / swap_total > max_swap_used_ratio:
            reasons.append("swap_pressure_high")
    thermal = metrics.get("thermal_state")
    if isinstance(thermal, dict) and thermal.get("state") == "observed" and thermal.get("value") not in ("nominal", "normal"):
        reasons.append("thermal_pressure")
    return {"admitted": not reasons, "reasons": reasons, "snapshot": snapshot}


def frozen_schedule(
    assignment_ids: tuple[str, ...] = tuple(f"assignment-{index}" for index in range(1, 7)),
    *,
    seed: int = SEED,
    cycles: int = DEFAULT_CYCLES,
) -> list[dict[str, Any]]:
    if len(assignment_ids) != ASSIGNMENTS_PER_TREATMENT or len(set(assignment_ids)) != len(assignment_ids):
        raise ContractError("the benchmark requires exactly six unique assignment ids")
    rng = random.Random(seed)
    schedule: list[dict[str, Any]] = []
    block = 0
    for cycle in range(cycles):
        rows = list(WILLIAMS_ROWS)
        rng.shuffle(rows)
        cache_state = "cold" if cycle % 2 == 0 else "warm"
        for row in rows:
            block += 1
            for position, width in enumerate(row, start=1):
                order = list(assignment_ids)
                random.Random(seed + block * 100 + width).shuffle(order)
                schedule.append(
                    {
                        "block": block,
                        "cycle": cycle + 1,
                        "position": position,
                        "width": width,
                        "cache_state": cache_state,
                        "assignment_ids": order,
                        "treatment_id": f"b{block:02d}-w{width}-{cache_state}",
                        "fixed_look": block if block in FIXED_LOOKS else None,
                    }
                )
    return schedule


def validate_manifest(value: dict[str, Any]) -> dict[str, Any]:
    assignments = value.get("assignments")
    if not isinstance(assignments, list) or len(assignments) != ASSIGNMENTS_PER_TREATMENT:
        raise ContractError("manifest assignments must contain exactly six entries")
    ids = []
    for assignment in assignments:
        if not isinstance(assignment, dict) or not isinstance(assignment.get("id"), str) or not assignment["id"]:
            raise ContractError("each assignment requires a non-empty string id")
        argv = assignment.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(item, str) and item for item in argv):
            raise ContractError(f"assignment {assignment['id']} requires a non-empty string argv")
        if assignment.get("workload_class", "light") not in ("light", "heavy"):
            raise ContractError("workload_class must be light or heavy")
        ids.append(assignment["id"])
    if len(set(ids)) != len(ids):
        raise ContractError("assignment ids must be unique")
    return value


class FileFifoAdmission:
    """Crash-recoverable FIFO tickets for the runner-owned heavy pool."""

    def __init__(self, root: Path, capacity: int = DEFAULT_HEAVY_CAPACITY, *, calibrated: bool = False) -> None:
        if capacity < 1:
            raise ContractError("heavy capacity must be positive")
        if capacity > DEFAULT_HEAVY_CAPACITY and not calibrated:
            raise ContractError("heavy capacity above one requires explicit clean-host calibration")
        self.root = root
        self.capacity = capacity
        self.root.mkdir(parents=True, exist_ok=True)

    def _live_tickets(self) -> list[Path]:
        live = []
        for path in sorted(self.root.glob("*.waiting.json")):
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
                identity = ProcessIdentity(**payload["identity"])
            except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
                path.replace(path.with_suffix(".invalid"))
                continue
            if identity_matches(identity):
                live.append(path)
            else:
                path.replace(path.with_suffix(".stale"))
        return live

    @contextlib.contextmanager
    def acquire(self, *, timeout: float = 60.0) -> Iterator[None]:
        identity = capture_process_identity(os.getpid())
        if identity is None:
            raise SafetyDenied("cannot establish admission-owner process identity")
        ticket = self.root / f"{time.time_ns():020d}-{uuid.uuid4().hex}.waiting.json"
        ticket.write_text(json.dumps({"identity": asdict(identity)}, sort_keys=True), encoding="utf-8")
        deadline = time.monotonic() + timeout
        try:
            while True:
                live = self._live_tickets()
                if ticket in live[: self.capacity]:
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError("timed out waiting for heavy admission")
                time.sleep(0.01)
            yield
        finally:
            if ticket.exists():
                ticket.replace(ticket.with_suffix(".released"))


def _peak_metric(samples: list[dict[str, Any]], name: str, unit: str) -> dict[str, Any]:
    values = [sample[name]["value"] for sample in samples if sample.get(name, {}).get("state") == "observed"]
    if values:
        return observed(max(values), unit, "owned-process-group-samples")
    states = [sample.get(name, {}).get("state") for sample in samples if sample.get(name)]
    state = "unsupported" if states and all(item == "unsupported" for item in states) else "missing"
    return unknown(state, unit, "owned-process-group-samples", "no observed sample")


def run_owned_process(
    argv: list[str],
    *,
    timeout: float,
    sampler: SystemSampler,
    sample_interval: float = 1.0,
    cwd: Optional[str] = None,
    env: Optional[dict[str, str]] = None,
) -> dict[str, Any]:
    started_at = utc_now()
    started = time.monotonic()
    with tempfile.TemporaryFile(mode="w+t", encoding="utf-8") as stdout, tempfile.TemporaryFile(mode="w+t", encoding="utf-8") as stderr:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stdout, stderr=stderr, text=True, start_new_session=True)
        identity = capture_process_identity(process.pid)
        if identity is None or identity.pgid != process.pid:
            process.terminate()
            process.wait(timeout=5)
            raise SafetyDenied("spawned process lacks a fenced, runner-owned process group identity")
        samples = []
        timed_out = False
        identity_lost = False
        while process.poll() is None:
            sample = sampler.process_group(identity)
            samples.append(sample)
            if not sample.get("identity_valid"):
                identity_lost = True
                break
            if time.monotonic() - started >= timeout:
                timed_out = True
                break
            time.sleep(min(sample_interval, max(0.001, timeout / 10)))
        signal_sent = None
        if process.poll() is None and (timed_out or identity_lost):
            if identity_matches(identity):
                os.killpg(identity.pgid, signal.SIGTERM)
                signal_sent = "SIGTERM"
                try:
                    process.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    if identity_matches(identity):
                        os.killpg(identity.pgid, signal.SIGKILL)
                        signal_sent = "SIGKILL"
            else:
                identity_lost = True
        if process.poll() is None:
            raise SafetyDenied("process identity lost; signal denied to avoid PID/PGID reuse")
        returncode = process.wait()
        stdout.seek(0)
        stderr.seek(0)
        stdout_text = stdout.read()
        stderr_text = stderr.read()
    status = "timeout" if timed_out else "invalid" if identity_lost else "succeeded" if returncode == 0 else "failed"
    return {
        "status": status,
        "started_at": started_at,
        "finished_at": utc_now(),
        "identity": asdict(identity),
        "signal_sent": signal_sent,
        "exit_code": returncode,
        "costs": {
            "wall_seconds": observed(time.monotonic() - started, "seconds", "runner-monotonic"),
            "cpu_seconds": _peak_metric(samples, "cpu_seconds", "seconds"),
            "peak_rss_bytes": _peak_metric(samples, "rss_bytes", "bytes"),
            "tokens": unknown("unsupported", "tokens", "runner", "command protocol supplied no token receipt"),
            "context_tokens": unknown("unsupported", "tokens", "runner", "command protocol supplied no context receipt"),
        },
        "provenance": {"argv": argv, "sample_count": len(samples), "sample_interval_seconds": sample_interval},
        "payload": {
            "stdout": stdout_text,
            "stderr": stderr_text,
            "stdout_sha256": hashlib.sha256(stdout_text.encode()).hexdigest(),
            "stderr_sha256": hashlib.sha256(stderr_text.encode()).hexdigest(),
        },
    }


def next_attempt(base_id: str, prior: list[dict[str, Any]]) -> tuple[Optional[str], Optional[str]]:
    chain = [item for item in prior if item.get("base_attempt_id") == base_id]
    if chain and chain[-1].get("status") == "succeeded":
        return None, None
    if not chain:
        return base_id, None
    return f"{base_id}.r{len(chain)}", chain[-1].get("attempt_id")


def append_attempt(path: Path, attempt: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(canonical_json(attempt).decode("utf-8") + "\n")


def load_attempts(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def treatment_attempts(
    manifest: dict[str, Any],
    treatment: dict[str, Any],
    *,
    sampler: SystemSampler,
    fifo: FileFifoAdmission,
    prior: list[dict[str, Any]],
    sample_interval: float,
) -> list[dict[str, Any]]:
    snapshot = sampler.host()
    decision = admission_decision(snapshot)
    assignments = {item["id"]: item for item in manifest["assignments"]}

    def execute(slot: int, assignment_id: str) -> Optional[dict[str, Any]]:
        base_id = f"{treatment['treatment_id']}:{assignment_id}"
        attempt_id, replaces = next_attempt(base_id, prior)
        if attempt_id is None:
            return None
        assignment = assignments[assignment_id]
        envelope: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "attempt_id": attempt_id,
            "base_attempt_id": base_id,
            "replaces_attempt_id": replaces,
            "assignment_id": assignment_id,
            "treatment": {key: treatment[key] for key in ("treatment_id", "block", "cycle", "position", "width", "cache_state")},
            "status": "denied",
            "costs": {
                "wall_seconds": unknown("missing", "seconds", "runner", "execution denied before start"),
                "cpu_seconds": unknown("missing", "seconds", "runner", "execution denied before start"),
                "peak_rss_bytes": unknown("missing", "bytes", "runner", "execution denied before start"),
                "tokens": unknown("unsupported", "tokens", "runner", "command protocol supplied no token receipt"),
                "context_tokens": unknown("unsupported", "tokens", "runner", "command protocol supplied no context receipt"),
            },
            "provenance": {"slot": slot, "host_admission": decision},
            "payload": {},
        }
        if decision["admitted"]:
            run = lambda: run_owned_process(
                assignment["argv"],
                timeout=float(assignment.get("timeout_seconds", 900)),
                sampler=sampler,
                sample_interval=sample_interval,
                cwd=assignment.get("cwd"),
                env={**os.environ, **assignment.get("env", {})},
            )
            try:
                if assignment.get("workload_class", "light") == "heavy":
                    with fifo.acquire(timeout=float(assignment.get("admission_timeout_seconds", 900))):
                        result = run()
                else:
                    result = run()
                envelope.update(result)
                envelope["provenance"]["host_admission"] = decision
                after = sampler.host()
                after_decision = admission_decision(after)
                envelope["provenance"]["host_after"] = after
                envelope["provenance"]["contamination"] = {
                    "state": "observed",
                    "value": not after_decision["admitted"],
                    "reasons": after_decision["reasons"],
                }
            except (SafetyDenied, TimeoutError) as exc:
                envelope["status"] = "denied"
                envelope["provenance"]["safety_error"] = str(exc)
        envelope["digest"] = digest({key: value for key, value in envelope.items() if key != "digest"})
        return envelope

    results: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=treatment["width"]) as pool:
        futures = [pool.submit(execute, slot, assignment_id) for slot, assignment_id in enumerate(treatment["assignment_ids"], start=1)]
        for future in futures:
            item = future.result()
            if item is not None:
                results.append(item)
    return results


def plan_envelope(manifest: dict[str, Any]) -> dict[str, Any]:
    assignment_ids = tuple(item["id"] for item in manifest["assignments"])
    plan = {
        "schema_version": SCHEMA_VERSION,
        "seed": SEED,
        "widths": list(WIDTHS),
        "assignments_per_treatment": ASSIGNMENTS_PER_TREATMENT,
        "cycles": DEFAULT_CYCLES,
        "fixed_looks": list(FIXED_LOOKS),
        "regression_limits": REGRESSION_LIMITS,
        "schedule": frozen_schedule(assignment_ids),
    }
    plan["digest"] = digest(plan)
    return plan


def run_benchmark(args: argparse.Namespace) -> dict[str, Any]:
    manifest = validate_manifest(json.loads(args.manifest.read_text(encoding="utf-8")))
    plan = plan_envelope(manifest)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "manifest.json").write_bytes(canonical_json({**manifest, "plan_digest": plan["digest"]}) + b"\n")
    (args.output_dir / "plan.json").write_bytes(canonical_json(plan) + b"\n")
    attempt_path = args.output_dir / "attempts.ndjson"
    prior = load_attempts(attempt_path)
    sampler = SystemSampler()
    fifo = FileFifoAdmission(args.output_dir / "heavy-queue", args.heavy_capacity, calibrated=args.calibrated_heavy_capacity)
    for treatment in plan["schedule"]:
        if treatment["block"] > args.look_blocks:
            break
        for attempt in treatment_attempts(
            manifest,
            treatment,
            sampler=sampler,
            fifo=fifo,
            prior=prior,
            sample_interval=args.sample_interval,
        ):
            append_attempt(attempt_path, attempt)
            prior.append(attempt)
    leaves: dict[str, dict[str, Any]] = {}
    for attempt in prior:
        leaves[attempt["base_attempt_id"]] = attempt
    statuses: dict[str, int] = {}
    for attempt in leaves.values():
        statuses[attempt["status"]] = statuses.get(attempt["status"], 0) + 1
    summary = {
        "schema_version": SCHEMA_VERSION,
        "plan_digest": plan["digest"],
        "look_blocks": args.look_blocks,
        "attempt_count": len(prior),
        "leaf_count": len(leaves),
        "statuses": statuses,
        "complete": len(leaves) == args.look_blocks * len(WIDTHS) * ASSIGNMENTS_PER_TREATMENT,
    }
    summary["digest"] = digest(summary)
    (args.output_dir / "summary.json").write_bytes(canonical_json(summary) + b"\n")
    return summary


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan", help="print the frozen schedule for a six-assignment manifest")
    plan.add_argument("--manifest", type=Path, required=True)
    run = sub.add_parser("run", help="execute a fixed look through the host-admitted runner")
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--output-dir", type=Path, required=True)
    run.add_argument("--look-blocks", type=int, choices=FIXED_LOOKS, default=FIXED_LOOKS[-1])
    run.add_argument("--heavy-capacity", type=int, default=DEFAULT_HEAVY_CAPACITY)
    run.add_argument("--calibrated-heavy-capacity", action="store_true")
    run.add_argument("--sample-interval", type=float, default=1.0)
    return result


def main(argv: Optional[list[str]] = None) -> int:
    args = parser().parse_args(argv)
    if args.command == "plan":
        manifest = validate_manifest(json.loads(args.manifest.read_text(encoding="utf-8")))
        print(canonical_json(plan_envelope(manifest)).decode("utf-8"))
        return 0
    summary = run_benchmark(args)
    print(canonical_json(summary).decode("utf-8"))
    return 0 if summary["complete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
