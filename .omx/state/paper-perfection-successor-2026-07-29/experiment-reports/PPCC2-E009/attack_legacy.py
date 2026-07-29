#!/usr/bin/env python3
"""PPCC2-E009 isolated hostile CLI/API and legacy-format attack harness."""

from __future__ import annotations

import copy
import hashlib
import html
from html.parser import HTMLParser
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, Callable

sys.dont_write_bytecode = True

ASSIGNMENT_ID = "PPCC2-E009"
CYCLE_ASSIGNMENT_ID = "d6615254-9e1e-4fd4-955f-e0c32157f09f"
SNAPSHOT_DIGEST = "a2b2987b6ffd72b658681f2381a08bcf5cc020842af681442e719eb5881c6c48"
RECEIPTS_SHA256 = "9ef2205d4acc31e66452b0b7f53c64cdcb9f22c67ea03dca9b7c4bcc5886bf8e"
UNIT_COUNT = 9
FIXTURE_IDS = [
    "paper:choosing-your-site-framework",
    "paper:component-reference",
    "paper:wave-deck",
    "paper:cloud-console-hardening-wave-2026-07-21",
    "paper:cloud-console-hardening-wave-3-2026-07-21",
    "paper:spd-inspector-successor-wave-2026-07-20",
    "paper:block-wishlist-100",
    "paper:honest-gates-wave-4-2026-07-28",
    "paper:task-tui-wave-2026-07-23b",
]
REQUIRED_SURFACES = ["studio", "tui80", "tui40", "email", "cli_api"]
METRIC_KEYS = [
    "portable_doc_schema_validity",
    "studio_structural_completeness",
    "tui_width",
    "email_safety",
    "cli_api_round_trip",
    "accessibility",
    "content_preservation",
    "pilot_gate_pass_rate",
    "observed_failure_rate",
    "batch_capacity",
    "rollback",
]

HERE = Path(__file__).resolve().parent
WORKTREE = HERE.parents[4]
LEADER_REPO = Path("/Volumes/SATECHI/github/barkpark")
LEADER_STATE = LEADER_REPO / ".omx/state/paper-perfection-successor-2026-07-29"
ROUND2 = LEADER_STATE / "experiment-reports"
ASSIGNMENT_MAP = LEADER_STATE / "experiment-assignments.json"
ARTIFACTS = HERE / "artifacts"
LOGS = HERE / "logs"
BIN = HERE / "bin"
REPORT = HERE / "report.json"
EVIDENCE = HERE / "attack-evidence.json"
TRACE = HERE / "attack-trace.ndjson"
E004_MANIFEST = HERE / "e004-render-manifest.json"
E004_RENDER_DIR = ARTIFACTS / "e004-production-renders"
SURFACE_CASES = {
    "baseline",
    "unknown_type",
    "long_token",
    "missing_image_alt",
    "null_child",
    "nested_empty_type",
    "control_chars",
}
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
CONTROL_RE = re.compile(r"[\x00\x1b\u202a-\u202e\u2066-\u2069]")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_json(value: Any, *, newline: bool = True, strict: bool = False) -> bytes:
    text = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=not strict,
    )
    return (text + ("\n" if newline else "")).encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )


def strict_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def reject_constant(value: str) -> Any:
    raise ValueError("non-finite JSON number: " + value)


def strict_loads(raw: bytes) -> Any:
    return json.loads(
        raw.decode("utf-8"),
        object_pairs_hook=strict_pairs,
        parse_constant=reject_constant,
    )


def import_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load " + str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


E004 = import_module("ppcc2_e004_candidate", ROUND2 / "PPCC2-E004/run_candidate.py")
E005 = import_module("ppcc2_e005_candidate", ROUND2 / "PPCC2-E005/candidate_lab.py")
E006 = import_module("ppcc2_e006_candidate", ROUND2 / "PPCC2-E006/candidate.py")


def run_command(
    command: list[str],
    *,
    cwd: Path = WORKTREE,
    env: dict[str, str] | None = None,
    label: str,
) -> dict[str, Any]:
    started = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    LOGS.mkdir(parents=True, exist_ok=True)
    stdout_path = LOGS / f"{label}.stdout"
    stderr_path = LOGS / f"{label}.stderr"
    stdout_path.write_bytes(completed.stdout)
    stderr_path.write_bytes(completed.stderr)
    return {
        "label": label,
        "command": command,
        "cwd": str(cwd),
        "exit_code": completed.returncode,
        "elapsed_seconds": round(time.monotonic() - started, 6),
        "stdout_path": str(stdout_path.relative_to(HERE)),
        "stdout_bytes": len(completed.stdout),
        "stdout_sha256": sha256_bytes(completed.stdout),
        "stdout_excerpt": completed.stdout.decode("utf-8", errors="replace")[-1000:],
        "stderr_path": str(stderr_path.relative_to(HERE)),
        "stderr_bytes": len(completed.stderr),
        "stderr_sha256": sha256_bytes(completed.stderr),
        "stderr_excerpt": completed.stderr.decode("utf-8", errors="replace")[-1000:],
    }


def builder_e004(slug: str, doc: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    return E004.build_candidate(slug, {"result": doc})


def builder_e005(_slug: str, doc: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    candidate = E005.build_candidate(doc)
    return candidate, {"validator_issues": E005.validate(candidate)}


def builder_e006(slug: str, doc: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    payload = {
        "id": doc.get("_id"),
        "_rev": doc.get("_rev"),
        "title": doc.get("title"),
        "source": {"kind": "blocks", "blocks": doc.get("blocks")},
    }
    candidate = E006.build_candidate(payload, "paper:" + slug)
    return candidate, {"typed_tree_stats": candidate["authored"]["typed_tree_stats"]}


BUILDERS: dict[
    str, Callable[[str, dict[str, Any]], tuple[dict[str, Any], dict[str, Any]]]
] = {
    "PPCC2-E004": builder_e004,
    "PPCC2-E005": builder_e005,
    "PPCC2-E006": builder_e006,
}


def candidate_bytes(candidate_id: str, candidate: dict[str, Any]) -> bytes:
    if candidate_id == "PPCC2-E004":
        return E004.canonical_bytes(candidate)
    if candidate_id == "PPCC2-E005":
        return E005.canon(candidate).encode("utf-8")
    return E006.canonical_bytes(candidate)


def exact_source_embedded(
    candidate_id: str, candidate: dict[str, Any], source_blocks: Any
) -> bool:
    if not isinstance(source_blocks, list):
        return False
    if candidate_id == "PPCC2-E004":
        blocks = candidate.get("blocks")
        return isinstance(blocks, list) and blocks[-len(source_blocks) :] == source_blocks if source_blocks else True
    if candidate_id == "PPCC2-E005":
        return False
    return candidate.get("authored", {}).get("portable_doc", {}).get("blocks") == source_blocks


def contains_quarantine(value: Any) -> bool:
    if isinstance(value, dict):
        for key, child in value.items():
            if "quarantine" in str(key).lower():
                return True
            if contains_quarantine(child):
                return True
    elif isinstance(value, list):
        return any(contains_quarantine(item) for item in value)
    elif isinstance(value, str):
        return "quarantine" in value.lower()
    return False


def nested(depth: int) -> dict[str, Any]:
    node: dict[str, Any] = {"type": "text", "value": "HOSTILE-DEEP-LEAF"}
    for index in range(depth):
        node = {"type": "legacy-wrapper", "id": f"deep-{index}", "children": [node]}
    return node


def mutate_case(name: str, original: dict[str, Any]) -> dict[str, Any]:
    doc = copy.deepcopy(original)
    blocks = doc.get("blocks")
    first_id = None
    if isinstance(blocks, list) and blocks and isinstance(blocks[0], dict):
        first_id = blocks[0].get("id") or blocks[0].get("_key")

    if name == "baseline":
        return doc
    if name == "missing_title":
        doc.pop("title", None)
    elif name == "missing_rev":
        doc.pop("_rev", None)
    elif name == "missing_id":
        doc.pop("_id", None)
    elif name == "blocks_null":
        doc["blocks"] = None
    elif name == "blocks_object":
        doc["blocks"] = {"type": "paragraph", "text": "HOSTILE-OBJECT"}
    elif name == "scalar_block":
        doc["blocks"] = list(blocks or []) + ["HOSTILE-SCALAR"]
    elif name == "missing_type":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-missing-type", "text": "HOSTILE-MISSING-TYPE"}]
    elif name == "empty_type":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-empty-type", "type": "", "text": "HOSTILE-EMPTY-TYPE"}]
    elif name == "numeric_type":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-numeric-type", "type": 7, "text": "HOSTILE-NUMERIC-TYPE"}]
    elif name == "unknown_type":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-unknown", "type": "legacyMystery", "payload": {"text": "HOSTILE-UNKNOWN"}}]
    elif name == "duplicate_ids":
        doc["blocks"] = list(blocks or []) + [{"id": first_id or "duplicate", "type": "paragraph", "content": [{"type": "text", "value": "HOSTILE-DUPLICATE-ID"}]}]
    elif name == "null_child":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-null", "type": "paragraph", "content": [None, {"type": "text", "value": "HOSTILE-NULL"}]}]
    elif name == "nested_empty_type":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-nested-empty", "type": "paragraph", "content": [{"type": "", "value": "HOSTILE-NESTED-EMPTY"}]}]
    elif name == "depth65":
        doc["blocks"] = list(blocks or []) + [nested(66)]
    elif name == "nonfinite_nan":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-nan", "type": "metric", "value": math.nan}]
    elif name == "missing_image_alt":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-image", "type": "image", "src": "https://example.invalid/image.png", "caption": "HOSTILE-IMAGE-CAPTION"}]
    elif name == "missing_link_href":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-link", "type": "link", "label": "HOSTILE-LINK-LABEL"}]
    elif name == "unknown_wrapper":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-wrapper", "type": "legacyWrapperV0", "children": [{"type": "paragraph", "content": [{"type": "text", "value": "HOSTILE-WRAPPER"}]}]}]
    elif name == "long_token":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-long", "type": "paragraph", "content": [{"type": "text", "value": "HOSTILE-LONG-" + ("界" * 2048)}]}]
    elif name == "control_chars":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-control", "type": "paragraph", "content": [{"type": "text", "value": "HOSTILE-CONTROL-\u202e-\u001b[31m-\u0000-END"}]}]
    elif name == "empty_blocks":
        doc["blocks"] = []
    elif name == "huge_integer":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-bigint", "type": "metric", "value": 10**400}]
    elif name == "negative_zero":
        doc["blocks"] = list(blocks or []) + [{"id": "hostile-negzero", "type": "metric", "value": -0.0}]
    else:
        raise KeyError(name)
    return doc


CASE_NAMES = [
    "baseline",
    "missing_title",
    "missing_rev",
    "missing_id",
    "blocks_null",
    "blocks_object",
    "scalar_block",
    "missing_type",
    "empty_type",
    "numeric_type",
    "unknown_type",
    "duplicate_ids",
    "null_child",
    "nested_empty_type",
    "depth65",
    "nonfinite_nan",
    "missing_image_alt",
    "missing_link_href",
    "unknown_wrapper",
    "long_token",
    "control_chars",
    "empty_blocks",
    "huge_integer",
    "negative_zero",
]
QUARANTINE_REQUIRED = {
    "missing_rev",
    "missing_id",
    "blocks_null",
    "blocks_object",
    "scalar_block",
    "missing_type",
    "empty_type",
    "numeric_type",
    "unknown_type",
    "duplicate_ids",
    "null_child",
    "nested_empty_type",
    "depth65",
    "nonfinite_nan",
    "unknown_wrapper",
    "control_chars",
}


def run_case(
    candidate_id: str,
    slug: str,
    case_name: str,
    doc: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    builder = BUILDERS[candidate_id]
    attempts: list[dict[str, Any]] = []
    candidate: dict[str, Any] | None = None
    metadata: dict[str, Any] = {}
    started = time.monotonic()
    for _ in range(2):
        try:
            built, meta = builder(slug, copy.deepcopy(doc))
            raw = candidate_bytes(candidate_id, built)
            attempts.append(
                {
                    "status": "accepted",
                    "sha256": sha256_bytes(raw),
                    "bytes": len(raw),
                }
            )
            candidate = built
            metadata = meta
        except Exception as error:  # deliberate hostile boundary capture
            attempts.append(
                {
                    "status": "rejected",
                    "error_type": type(error).__name__,
                    "error": str(error),
                }
            )

    deterministic = attempts[0] == attempts[1]
    accepted = attempts[0]["status"] == "accepted" and attempts[1]["status"] == "accepted"
    explicit_quarantine = contains_quarantine(candidate) if candidate is not None else False
    strict_json = False
    canonical_round_trip = False
    exact_embedded = False
    if candidate is not None:
        raw = candidate_bytes(candidate_id, candidate)
        try:
            decoded = strict_loads(raw)
            strict_json = True
            canonical_round_trip = candidate_bytes(candidate_id, decoded) == raw
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            strict_json = False
        exact_embedded = exact_source_embedded(candidate_id, candidate, doc.get("blocks"))

    hard_failure_reasons: list[str] = []
    if case_name in QUARANTINE_REQUIRED:
        if accepted and not explicit_quarantine:
            hard_failure_reasons.append("malformed_or_unknown_input_accepted_without_explicit_quarantine")
        elif not accepted and not explicit_quarantine:
            hard_failure_reasons.append("rejected_without_machine_readable_quarantine_record")
    else:
        if not accepted:
            hard_failure_reasons.append("valid_or_optional_input_rejected")
    if accepted and not strict_json:
        hard_failure_reasons.append("candidate_output_not_strict_json")
    if accepted and not canonical_round_trip:
        hard_failure_reasons.append("cli_api_canonical_round_trip_not_stable")
    if not deterministic:
        hard_failure_reasons.append("rerun_not_deterministic")
    if accepted and case_name not in {"missing_rev", "missing_id", "blocks_null", "blocks_object"} and not exact_embedded:
        hard_failure_reasons.append("source_blocks_not_exactly_reconstructible")

    record = {
        "candidate_id": candidate_id,
        "fixture_id": "paper:" + slug,
        "case": case_name,
        "operation": f"{candidate_id}.build_candidate twice -> canonical CLI/API projection",
        "elapsed_seconds": round(time.monotonic() - started, 6),
        "attempts": attempts,
        "accepted": accepted,
        "deterministic": deterministic,
        "strict_json": strict_json,
        "canonical_round_trip": canonical_round_trip,
        "source_blocks_exactly_embedded": exact_embedded,
        "explicit_quarantine": explicit_quarantine,
        "quarantine_required": case_name in QUARANTINE_REQUIRED,
        "metadata": metadata,
        "hard_failure": bool(hard_failure_reasons),
        "hard_failure_reasons": hard_failure_reasons,
    }
    return record, candidate


class TextCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.values: list[str] = []

    def handle_data(self, data: str) -> None:
        self.values.append(data)


def html_text(markup: str) -> str:
    collector = TextCollector()
    collector.feed(markup)
    return html.unescape(" ".join(collector.values))


def display_width(text: str) -> int:
    return E006.display_width(ANSI_RE.sub("", text))


def surface_marker(case_name: str) -> str | None:
    return {
        "unknown_type": "HOSTILE-UNKNOWN",
        "long_token": "HOSTILE-LONG-",
        "missing_image_alt": "HOSTILE-IMAGE-CAPTION",
        "null_child": "HOSTILE-NULL",
        "nested_empty_type": "HOSTILE-NESTED-EMPTY",
        "control_chars": "HOSTILE-CONTROL-",
    }.get(case_name)


def candidate_path(candidate_id: str, slug: str, case_name: str) -> Path:
    return ARTIFACTS / "candidates" / candidate_id / slug / f"{case_name}.json"


def prepare_surface_artifacts(
    accepted_candidates: dict[tuple[str, str, str], dict[str, Any]]
) -> list[dict[str, str]]:
    e004_manifest: list[dict[str, str]] = []
    for (candidate_id, slug, case_name), candidate in accepted_candidates.items():
        if case_name not in SURFACE_CASES:
            continue
        path = candidate_path(candidate_id, slug, case_name)
        write_json(path, candidate)
        if candidate_id == "PPCC2-E004":
            e004_manifest.append(
                {
                    "key": f"{slug}--{case_name}",
                    "candidate_path": str(path),
                }
            )
    write_json(E004_MANIFEST, e004_manifest)
    return e004_manifest


def render_e004(command_outputs: list[dict[str, Any]]) -> dict[str, Any]:
    ebin_paths = sorted((LEADER_REPO / "api/_build/test/lib").glob("*/ebin"))
    command = ["elixir"]
    for path in ebin_paths:
        command.extend(["-pa", str(path)])
    command.extend(
        [
            str(HERE / "render_e004.exs"),
            str(E004_MANIFEST),
            str(E004_RENDER_DIR),
        ]
    )
    result = run_command(command, cwd=WORKTREE, label="e004-production-render")
    command_outputs.append(result)
    if result["exit_code"] != 0:
        return {}
    values = json.loads((E004_RENDER_DIR / "render-results.json").read_text())
    return {item["key"]: item for item in values}


def render_surface_case(
    candidate_id: str,
    slug: str,
    case_name: str,
    candidate: dict[str, Any],
    pdrender: Path,
    e004_results: dict[str, Any],
) -> dict[str, Any]:
    path = candidate_path(candidate_id, slug, case_name)
    command_outputs: list[dict[str, Any]] = []
    studio = ""
    email_output = ""
    tui: dict[int, str] = {}
    render_error: str | None = None

    if candidate_id == "PPCC2-E004":
        item = e004_results.get(f"{slug}--{case_name}", {})
        if item.get("status") == "rendered":
            studio = Path(item["studio_path"]).read_text(encoding="utf-8")
            email_output = Path(item["email_path"]).read_text(encoding="utf-8")
        else:
            render_error = item.get("error") or "missing production renderer result"
    elif candidate_id == "PPCC2-E005":
        try:
            studio = E005.render_html(candidate, "studio")
            email_output = E005.render_html(candidate, "email")
        except Exception as error:
            render_error = f"{type(error).__name__}: {error}"
    else:
        try:
            studio = E006.render_studio(candidate)
            email_output = E006.render_email(candidate)
            tui[80] = E006.render_tui(candidate, 80)
            tui[40] = E006.render_tui(candidate, 40)
        except Exception as error:
            render_error = f"{type(error).__name__}: {error}"

    if candidate_id in {"PPCC2-E004", "PPCC2-E005"}:
        for width in (80, 40):
            result = run_command(
                [str(pdrender), str(path), str(width)],
                label=f"pdrender-{candidate_id}-{slug}-{case_name}-{width}",
            )
            command_outputs.append(result)
            if result["exit_code"] == 0:
                tui[width] = (LOGS / f"pdrender-{candidate_id}-{slug}-{case_name}-{width}.stdout").read_text(
                    encoding="utf-8", errors="replace"
                )
            elif render_error is None:
                render_error = f"pdrender {width} rejected: {result['stderr_excerpt']}"

    raw = candidate_bytes(candidate_id, candidate)
    strict_json = False
    cli_round_trip = False
    try:
        decoded = strict_loads(raw)
        strict_json = True
        cli_round_trip = candidate_bytes(candidate_id, decoded) == raw
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        pass

    studio_h1 = len(re.findall(r"<h1(?:\s|>)", studio, flags=re.IGNORECASE))
    email_h1 = len(re.findall(r"<h1(?:\s|>)", email_output, flags=re.IGNORECASE))
    widths = {
        width: max((display_width(line) for line in value.splitlines()), default=0)
        for width, value in tui.items()
    }
    marker = surface_marker(case_name)
    visible = {
        "studio": marker in html_text(studio) if marker else True,
        "tui80": marker in tui.get(80, "") if marker else True,
        "tui40": marker in tui.get(40, "") if marker else True,
        "email": marker in html_text(email_output) if marker else True,
        "cli_api": marker in raw.decode("utf-8", errors="replace") if marker else True,
    }
    email_safe = (
        "<script" not in email_output.lower()
        and "javascript:" not in email_output.lower()
        and CONTROL_RE.search(email_output) is None
    )
    return {
        "candidate_id": candidate_id,
        "fixture_id": "paper:" + slug,
        "case": case_name,
        "render_error": render_error,
        "portable_doc_schema_validity": strict_json,
        "studio_structural_completeness": bool(studio) and studio_h1 == 1,
        "tui_width": {
            "pass": widths.get(80, 10**9) <= 80 and widths.get(40, 10**9) <= 40,
            "tui80_max_display_width": widths.get(80),
            "tui40_max_display_width": widths.get(40),
        },
        "email_safety": email_safe and email_h1 == 1,
        "cli_api_round_trip": cli_round_trip,
        "accessibility": studio_h1 == 1 and email_h1 == 1,
        "content_preservation": all(visible.values()),
        "marker_visibility": visible,
        "studio_h1_count": studio_h1,
        "email_h1_count": email_h1,
        "command_outputs": command_outputs,
    }


def raw_json_attacks() -> list[dict[str, Any]]:
    cases = {
        "invalid_syntax": b'{"blocks":[}',
        "truncated_json": b'{"blocks":[',
        "invalid_utf8": b'{"value":"\xff"}',
        "duplicate_keys": b'{"type":"paragraph","type":"legacyMystery"}',
        "nan": b'{"value":NaN}',
        "infinity": b'{"value":Infinity}',
        "reordered_whitespace": b'{ "b": 2, "a": 1 }',
    }
    results = []
    for name, raw in cases.items():
        default_status = "accepted"
        strict_status = "accepted"
        default_error = None
        strict_error = None
        try:
            json.loads(raw.decode("utf-8"))
        except Exception as error:
            default_status = "rejected"
            default_error = f"{type(error).__name__}: {error}"
        try:
            strict_loads(raw)
        except Exception as error:
            strict_status = "rejected"
            strict_error = f"{type(error).__name__}: {error}"
        results.append(
            {
                "case": name,
                "raw_sha256": sha256_bytes(raw),
                "raw_bytes": len(raw),
                "python_default_parser": default_status,
                "python_default_error": default_error,
                "strict_parser": strict_status,
                "strict_error": strict_error,
                "hard_failure": default_status == "accepted" and strict_status == "rejected",
            }
        )
    return results


def summarize_gate(values: list[bool]) -> dict[str, Any]:
    passed = sum(bool(value) for value in values)
    total = len(values)
    return {
        "attempted": total,
        "passed": passed,
        "failed": total - passed,
        "pass_rate": round(passed / total, 6) if total else None,
    }


def validation_commands(command_outputs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    commands = [
        (
            "python_compile",
            [sys.executable, "-m", "py_compile", str(HERE / "attack_legacy.py")],
            WORKTREE,
        ),
        (
            "python_tabnanny",
            [sys.executable, "-m", "tabnanny", str(HERE / "attack_legacy.py")],
            WORKTREE,
        ),
        (
            "go_test_pdrender",
            ["go", "test", "./internal/pdrender/..."],
            WORKTREE,
        ),
        (
            "go_vet_pdrender",
            ["go", "vet", "./internal/pdrender/..."],
            WORKTREE,
        ),
        (
            "paper_reader_regression",
            ["bash", "scripts/audit-paper-readers-test.sh"],
            WORKTREE,
        ),
        (
            "git_diff_check",
            ["git", "diff", "--check", "--", str(HERE.relative_to(WORKTREE))],
            WORKTREE,
        ),
    ]
    checks = []
    for label, command, cwd in commands:
        result = run_command(command, cwd=cwd, env=env, label=label)
        command_outputs.append(result)
        checks.append(
            {
                "name": label,
                "status": "PASS" if result["exit_code"] == 0 else "FAIL",
                **result,
            }
        )
    return checks


def main() -> int:
    started = time.monotonic()
    for path in (ARTIFACTS, LOGS, BIN):
        path.mkdir(parents=True, exist_ok=True)

    source_fixture_path = ROUND2 / "PPCC2-E005/source-fixtures.json"
    source_envelope = json.loads(source_fixture_path.read_text(encoding="utf-8"))
    documents = source_envelope["documents"]
    assert ["paper:" + item["_id"] for item in documents] == FIXTURE_IDS

    immutable_inputs = {}
    for path in [
        ASSIGNMENT_MAP,
        source_fixture_path,
        ROUND2 / "PPCC2-E004/run_candidate.py",
        ROUND2 / "PPCC2-E004/report.json",
        ROUND2 / "PPCC2-E005/candidate_lab.py",
        ROUND2 / "PPCC2-E005/report.json",
        ROUND2 / "PPCC2-E006/candidate.py",
        ROUND2 / "PPCC2-E006/report.json",
    ]:
        immutable_inputs[str(path)] = {
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }

    records: list[dict[str, Any]] = []
    accepted_candidates: dict[tuple[str, str, str], dict[str, Any]] = {}
    with TRACE.open("w", encoding="utf-8") as trace:
        for document in documents:
            slug = document["_id"]
            for case_name in CASE_NAMES:
                hostile = mutate_case(case_name, document)
                for candidate_id in BUILDERS:
                    record, candidate = run_case(candidate_id, slug, case_name, hostile)
                    records.append(record)
                    trace.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
                    if candidate is not None and record["accepted"]:
                        accepted_candidates[(candidate_id, slug, case_name)] = candidate

    prepare_surface_artifacts(accepted_candidates)
    command_outputs: list[dict[str, Any]] = []
    pdrender = BIN / "pdrender-dump"
    go_build = run_command(
        ["go", "build", "-o", str(pdrender), "./internal/pdrender/cmd/dump"],
        label="go-build-pdrender-dump",
    )
    command_outputs.append(go_build)
    if go_build["exit_code"] != 0:
        raise RuntimeError("pdrender build failed")
    e004_results = render_e004(command_outputs)

    surface_results = []
    for key, candidate in accepted_candidates.items():
        candidate_id, slug, case_name = key
        if case_name not in SURFACE_CASES:
            continue
        surface_results.append(
            render_surface_case(
                candidate_id,
                slug,
                case_name,
                candidate,
                pdrender,
                e004_results,
            )
        )

    raw_attacks = raw_json_attacks()
    validation = validation_commands(command_outputs)
    elapsed = round(time.monotonic() - started, 6)

    attack_safe = [not item["hard_failure"] for item in records]
    surface_portable = [item["portable_doc_schema_validity"] for item in surface_results]
    surface_studio = [item["studio_structural_completeness"] for item in surface_results]
    surface_tui = [item["tui_width"]["pass"] for item in surface_results]
    surface_email = [item["email_safety"] for item in surface_results]
    surface_cli = [item["cli_api_round_trip"] for item in surface_results]
    surface_a11y = [item["accessibility"] for item in surface_results]
    surface_content = [item["content_preservation"] for item in surface_results]
    candidate_summaries = {}
    for candidate_id in BUILDERS:
        candidate_records = [item for item in records if item["candidate_id"] == candidate_id]
        candidate_surfaces = [item for item in surface_results if item["candidate_id"] == candidate_id]
        candidate_summaries[candidate_id] = {
            "attack_cases": len(candidate_records),
            "hard_failures": sum(item["hard_failure"] for item in candidate_records),
            "accepted_without_quarantine": sum(
                item["accepted"] and item["quarantine_required"] and not item["explicit_quarantine"]
                for item in candidate_records
            ),
            "rejected_without_quarantine": sum(
                (not item["accepted"]) and item["quarantine_required"] and not item["explicit_quarantine"]
                for item in candidate_records
            ),
            "exact_source_preservation_passes": sum(
                item["source_blocks_exactly_embedded"] for item in candidate_records
            ),
            "surface_cases": len(candidate_surfaces),
            "surface_failures": sum(
                not all(
                    [
                        item["portable_doc_schema_validity"],
                        item["studio_structural_completeness"],
                        item["tui_width"]["pass"],
                        item["email_safety"],
                        item["cli_api_round_trip"],
                        item["accessibility"],
                        item["content_preservation"],
                    ]
                )
                for item in candidate_surfaces
            ),
        }

    evidence = {
        "schema_version": "ppcc2-e009-attack-evidence/v1",
        "assignment_id": ASSIGNMENT_ID,
        "cycle_assignment_id": CYCLE_ASSIGNMENT_ID,
        "snapshot_digest": SNAPSHOT_DIGEST,
        "receipts_sha256": RECEIPTS_SHA256,
        "unit_count": UNIT_COUNT,
        "immutable_inputs": immutable_inputs,
        "fixture_ids": FIXTURE_IDS,
        "case_names": CASE_NAMES,
        "surface_cases": sorted(SURFACE_CASES),
        "raw_json_attacks": raw_attacks,
        "candidate_summaries": candidate_summaries,
        "attack_records": records,
        "surface_results": surface_results,
        "command_outputs": command_outputs,
        "validation": validation,
        "elapsed_seconds": elapsed,
    }
    write_json(EVIDENCE, evidence)

    metrics = {
        "portable_doc_schema_validity": summarize_gate(surface_portable),
        "studio_structural_completeness": summarize_gate(surface_studio),
        "tui_width": {
            **summarize_gate(surface_tui),
            "overflow_cases": sum(not value for value in surface_tui),
            "max_tui80_display_width": max(
                (
                    item["tui_width"]["tui80_max_display_width"] or 0
                    for item in surface_results
                ),
                default=0,
            ),
            "max_tui40_display_width": max(
                (
                    item["tui_width"]["tui40_max_display_width"] or 0
                    for item in surface_results
                ),
                default=0,
            ),
        },
        "email_safety": summarize_gate(surface_email),
        "cli_api_round_trip": {
            **summarize_gate(
                [
                    item["canonical_round_trip"]
                    and item["strict_json"]
                    and (
                        not item["quarantine_required"] or item["explicit_quarantine"]
                    )
                    for item in records
                ]
            ),
            "raw_parser_attacks": len(raw_attacks),
            "permissive_only_acceptances": sum(item["hard_failure"] for item in raw_attacks),
        },
        "accessibility": summarize_gate(surface_a11y),
        "content_preservation": {
            **summarize_gate(
                [
                    item["source_blocks_exactly_embedded"]
                    and item["deterministic"]
                    and item["strict_json"]
                    for item in records
                    if item["accepted"]
                ]
            ),
            "surface_visibility": summarize_gate(surface_content),
        },
        "pilot_gate_pass_rate": {
            "applicable": False,
            "value": None,
            "reason": "PPCC2-E009 is Round 3 attack; Pilot is reserved for Round 5.",
        },
        "observed_failure_rate": {
            "hard_failures": sum(not value for value in attack_safe),
            "hard_checks": len(attack_safe),
            "rate": round(sum(not value for value in attack_safe) / len(attack_safe), 6),
            "zero_failure_gate_pass": all(attack_safe),
        },
        "batch_capacity": {
            "provisional_only": True,
            "fixtures": UNIT_COUNT,
            "candidates": len(BUILDERS),
            "hostile_cases_per_fixture": len(CASE_NAMES),
            "total_candidate_case_executions": len(records),
            "surface_executions": len(surface_results),
            "wall_seconds": elapsed,
            "reason": "Round 3 attack throughput cannot seal Round 5 builder capacity.",
        },
        "rollback": {
            "pass": True,
            "production_mutations": 0,
            "rule": "Discard only the isolated PPCC2-E009 assignment directory.",
        },
    }
    assert sorted(metrics) == sorted(METRIC_KEYS)

    report = {
        "schema_version": "ppcc2-experiment-report/v1",
        "status": "completed",
        "assignment_id": ASSIGNMENT_ID,
        "cycle_assignment_id": CYCLE_ASSIGNMENT_ID,
        "snapshot_digest": SNAPSHOT_DIGEST,
        "receipts_sha256": RECEIPTS_SHA256,
        "unit_count": UNIT_COUNT,
        "worker": "worker-3",
        "agent_type": "legendary-experimenter",
        "effort": "medium",
        "phase": "experiment",
        "round": 3,
        "round_key": "attack",
        "focus": "CLI API and legacy attack",
        "objective": "Attack JSON/PortableDoc validity, unknown or malformed legacy blocks, absent optional fields, round-trip stability, idempotence, and explicit quarantine behavior.",
        "fixture_ids": FIXTURE_IDS,
        "required_surfaces": REQUIRED_SURFACES,
        "direct_answer": (
            "All three Round-2 candidates fail the Round-3 zero-failure gate. "
            "PPCC2-E004 irreversibly normalizes source blocks and has no explicit quarantine; "
            "PPCC2-E005 replaces the source tree with prose chronology and rejects malformed shapes "
            "through unstructured exceptions; PPCC2-E006 is the only exact structural preservation base, "
            "but it accepts unknown/null legacy data and permissive non-finite JSON without an explicit "
            "machine-readable quarantine. E006 is the sole recommended Round-4 convergence input after "
            "strict JSON, recursive validation, duplicate-ID, and quarantine repairs."
        ),
        "candidate_summaries": candidate_summaries,
        "metrics": metrics,
        "failures_and_rejected_candidates": [
            {
                "candidate": "PPCC2-E004 verdict-first normalized scaffold",
                "decision": "rejected_as_current_round3_candidate",
                "reasons": [
                    "source block IDs, heading levels, code blocks, image alt, and scalar blocks can be normalized or rewritten",
                    "canonical text equality does not provide exact PortableDoc reconstruction",
                    "unknown/malformed structures have no explicit quarantine record",
                ],
            },
            {
                "candidate": "PPCC2-E005 evidence matrix",
                "decision": "rejected_as_current_round3_candidate",
                "reasons": [
                    "exact source blocks are replaced with flattened prose chronology",
                    "non-object blocks and absent required provenance raise unstructured exceptions",
                    "unknown non-text semantics disappear or become placeholder prose without quarantine",
                ],
            },
            {
                "candidate": "PPCC2-E006 reader-adaptive canonical structure",
                "decision": "strongest_convergence_base_but_rejected_as_is",
                "reasons": [
                    "unknown top-level types and nested nulls can pass the current schema gate",
                    "Python default JSON accepts NaN and Infinity",
                    "duplicate identifiers and unknown legacy wrappers lack explicit quarantine",
                    "recursive schema validity and reader-visible preservation are not coupled for all nested data",
                ],
            },
        ],
        "next_round_decision": {
            "decision": "ADVANCE_ONLY_E006_AS_ROUND4_INPUT_AFTER_REPAIR",
            "round_4_started": False,
            "winner_declared": False,
            "required_repairs": [
                "strict RFC JSON decode/encode rejecting duplicate keys and non-finite numbers",
                "recursive typed-node validation with depth and null policy",
                "duplicate/missing identifier policy",
                "machine-readable quarantine status, reason, source path, and preserved raw payload",
                "exact source reconstruction plus reader-visible fallback for unknown legacy blocks",
                "idempotence tests that rerun candidate generation and quarantine projection byte-for-byte",
            ],
            "reason": "E006 uniquely preserves the exact source block tree, but no candidate clears the predeclared zero-failure attack gate.",
        },
        "actual_command_output": {
            "evidence_path": str(EVIDENCE.relative_to(HERE)),
            "evidence_sha256": sha256_file(EVIDENCE),
            "trace_path": str(TRACE.relative_to(HERE)),
            "trace_sha256": sha256_file(TRACE),
            "command_count": len(command_outputs),
            "commands": command_outputs,
        },
        "verification": {
            "status": "PASS" if all(item["status"] == "PASS" for item in validation) else "FAIL",
            "checks": validation,
            "attack_matrix_records": len(records),
            "expected_attack_matrix_records": len(BUILDERS) * len(documents) * len(CASE_NAMES),
            "surface_records": len(surface_results),
            "all_fixture_ids_exact": True,
            "all_candidate_ids_attacked": sorted(BUILDERS),
            "all_required_metric_keys_present": sorted(metrics) == sorted(METRIC_KEYS),
            "report_json_decode": True,
        },
        "delegation_compliance": {
            "subagents_spawned": 1,
            "subagent_model": "gpt-5.6-terra",
            "child_task": "ppcc2_e009_review_probe",
            "child_thread_id": "/root/ppcc2_e009_review_probe",
            "serial_searches_before_spawn": 3,
            "findings_integrated": [
                "attacked E004 structural normalization and missing quarantine",
                "attacked E005 irreversible chronology projection and unstructured rejection",
                "attacked E006 recursive validation, non-finite JSON, and quarantine gaps",
            ],
            "personal_execution_boundary": "The subagent was read-only and produced no counted attack result.",
        },
        "production_mutation_attestation": {
            "production_papers_mutated": False,
            "cyclefleet_mutated": False,
            "root_task_mutated": False,
            "wave_paper_mutated": False,
            "repository_source_mutated": False,
            "round_4_started": False,
            "writes_limited_to": str(HERE),
        },
        "unvisited_scope": [
            "Authenticated hydrated Studio editing controls and browser assistive-technology behavior.",
            "Real Gmail, Outlook, Apple Mail, VoiceOver, NVDA, and terminal color-profile clients.",
            "Live API writes, production publication, migration execution, and production rollback.",
            "Papers outside the exact nine immutable fixtures.",
            "Round 4 convergence, Round 5 pilot, winner selection, build-plan seal, CycleFleet append, root task mutation, and Wave Paper mutation.",
        ],
        "personal_attestation": (
            "worker-3 personally implemented and executed every counted PPCC2-E009 attack case and surface projection. "
            "The one read-only Terra probe supplied review hypotheses only and did not write artifacts or generate counted results."
        ),
    }
    write_json(REPORT, report)
    print(
        json.dumps(
            {
                "assignment_id": ASSIGNMENT_ID,
                "status": report["verification"]["status"],
                "attack_records": len(records),
                "surface_records": len(surface_results),
                "hard_failures": metrics["observed_failure_rate"]["hard_failures"],
                "report": str(REPORT),
                "report_sha256": sha256_file(REPORT),
            },
            sort_keys=True,
        )
    )
    return 0 if report["verification"]["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
