#!/usr/bin/env python3
"""Hostile-reader attack harness for the three PPCC2 Round-2 candidates."""

from __future__ import annotations

import argparse
import copy
import datetime
import hashlib
import html
from html.parser import HTMLParser
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import time
from typing import Any, Iterable, Mapping, Sequence
import unicodedata


ASSIGNMENT_ID = "PPCC2-E008"
CYCLE_ASSIGNMENT_ID = "8ddaa122-30d5-410d-842b-7c4b21da498a"
SNAPSHOT_DIGEST = "25ad3ff132fba732942a8259e0f66d51d1d30abfb55c0b4223638c8355eb4176"
RECEIPTS_SHA256 = "9ef2205d4acc31e66452b0b7f53c64cdcb9f22c67ea03dca9b7c4bcc5886bf8e"
UNIT_COUNT = 9
CANDIDATE_IDS = ("PPCC2-E004", "PPCC2-E005", "PPCC2-E006")
REQUIRED_SURFACES = ("studio", "tui80", "tui40", "email", "cli_api")
METRIC_KEYS = (
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
)
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
INPUTS = HERE / "inputs"
ARTIFACTS = HERE / "artifacts"
BIN = ARTIFACTS / "bin"
CASES = ARTIFACTS / "cases"
COMMAND_LOG = ARTIFACTS / "command-log.json"
RUN_SUMMARY = ARTIFACTS / "run-summary.json"
REPORT = HERE / "report.json"

ATTACK_MARKERS = (
    "PPCC2_ATTACK_LONG",
    "PPCC2_ATTACK_TABLE_R1",
    "PPCC2_ATTACK_CODE",
    "PPCC2_ATTACK_SAFE_URL",
    "PPCC2_ATTACK_UNSAFE_URL",
    "PPCC2_ATTACK_NESTED",
)
SAFE_URL = (
    "https://example.test/ppcc2/attack/"
    + "very-long-path-segment/" * 8
    + "?proof=PPCC2_ATTACK_SAFE_URL"
)
UNSAFE_URL = "javascript:alert('PPCC2_ATTACK_UNSAFE_URL')"
LONG_TOKEN = "PPCC2_ATTACK_LONG_" + ("界" * 48) + ("A" * 180)


def canonical_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def text_cell(value: str) -> list[dict[str, str]]:
    return [{"type": "text", "value": value}]


def hostile_document(source: Mapping[str, Any]) -> dict[str, Any]:
    """Append deterministic hostile blocks without changing the frozen source object."""
    document = copy.deepcopy(dict(source))
    blocks = copy.deepcopy(document.get("blocks"))
    if not isinstance(blocks, list):
        raise ValueError("source blocks must be a list")
    suffix = str(document["_id"]).replace("/", "-")
    blocks.extend(
        [
            {
                "id": f"{suffix}-attack-long",
                "type": "paragraph",
                "content": text_cell(
                    f"{LONG_TOKEN} with whitespace after the token and a literal "
                    "<script> marker that must remain text."
                ),
            },
            {
                "id": f"{suffix}-attack-table",
                "type": "table",
                "head": [text_cell("Attack"), text_cell("Observed value")],
                "rows": [
                    [
                        text_cell("PPCC2_ATTACK_TABLE_R1"),
                        text_cell("wide table cell " + ("W" * 220)),
                    ],
                    [
                        text_cell("PPCC2_ATTACK_TABLE_R2"),
                        text_cell("Unicode widths: 界界界 and combining e\u0301."),
                    ],
                ],
            },
            {
                "id": f"{suffix}-attack-code",
                "type": "code",
                "language": "html",
                "value": (
                    "PPCC2_ATTACK_CODE\n"
                    "<script>alert('must be escaped, never executed')</script>\n"
                    "const payload = '" + ("X" * 220) + "';"
                ),
            },
            {
                "id": f"{suffix}-attack-safe-url",
                "type": "action",
                "label": "PPCC2_ATTACK_SAFE_URL",
                "href": SAFE_URL,
                "priority": "primary",
            },
            {
                "id": f"{suffix}-attack-unsafe-url",
                "type": "action",
                "label": "PPCC2_ATTACK_UNSAFE_URL",
                "href": UNSAFE_URL,
                "priority": "secondary",
            },
            {
                "id": f"{suffix}-attack-nested",
                "type": "section",
                "title": "PPCC2_ATTACK_NESTED",
                "layout": {"mode": "grid", "tracks": 2},
                "blocks": [
                    {
                        "id": f"{suffix}-attack-nested-p",
                        "type": "paragraph",
                        "content": text_cell(
                            "Nested attack evidence must linearize after the URL rows."
                        ),
                    }
                ],
            },
        ]
    )
    document["blocks"] = blocks
    return document


def display_width(value: str) -> int:
    width = 0
    for char in value:
        if unicodedata.combining(char):
            continue
        width += 2 if unicodedata.east_asian_width(char) in {"F", "W"} else 1
    return width


class HTMLAttackProbe(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.text: list[str] = []
        self.h1_count = 0
        self.script_count = 0
        self.details_count = 0
        self.event_attributes: list[str] = []
        self.unsafe_url_attributes: list[str] = []
        self.images_missing_alt = 0

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        attr_map = dict(attrs)
        lower_tag = tag.lower()
        if lower_tag == "h1":
            self.h1_count += 1
        if lower_tag == "script":
            self.script_count += 1
        if lower_tag == "details":
            self.details_count += 1
        if lower_tag == "img" and not str(attr_map.get("alt") or "").strip():
            self.images_missing_alt += 1
        for key, value in attrs:
            key = key.lower()
            raw = html.unescape(value or "").strip().lower()
            if key.startswith("on"):
                self.event_attributes.append(key)
            if key in {"href", "src", "action", "formaction"} and re.match(
                r"^(javascript|data|vbscript)\s*:", raw
            ):
                self.unsafe_url_attributes.append(f"{key}={raw[:120]}")

    def handle_data(self, data: str) -> None:
        self.text.append(data)


def probe_html(markup: str) -> dict[str, Any]:
    probe = HTMLAttackProbe()
    probe.feed(markup)
    return {
        "h1_count": probe.h1_count,
        "script_count": probe.script_count,
        "details_count": probe.details_count,
        "event_attributes": probe.event_attributes,
        "unsafe_url_attributes": probe.unsafe_url_attributes,
        "images_missing_alt": probe.images_missing_alt,
        "text": html.unescape(" ".join(probe.text)),
    }


def normalized(value: str) -> str:
    return "".join(
        char
        for char in unicodedata.normalize("NFKC", html.unescape(value))
        if not char.isspace()
    )


def markers_present(value: str, include_safe_url: bool = False) -> bool:
    compact = normalized(value)
    required = list(ATTACK_MARKERS)
    if include_safe_url:
        required.append(SAFE_URL)
    return all(normalized(marker) in compact for marker in required)


def markers_in_order(value: str) -> bool:
    compact = normalized(value)
    positions = [compact.find(normalized(marker)) for marker in ATTACK_MARKERS]
    return all(position >= 0 for position in positions) and positions == sorted(positions)


def run_command(
    command: Sequence[str],
    command_log: list[dict[str, Any]],
    *,
    cwd: Path = REPO,
    output_path: Path | None = None,
) -> subprocess.CompletedProcess[bytes]:
    started = time.monotonic()
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(completed.stdout)
    command_log.append(
        {
            "command": list(command),
            "cwd": str(cwd),
            "exit_code": completed.returncode,
            "elapsed_seconds": round(time.monotonic() - started, 6),
            "stdout_bytes": len(completed.stdout),
            "stdout_sha256": sha256_bytes(completed.stdout),
            "stdout_tail": completed.stdout.decode("utf-8", errors="replace")[-500:],
            "stderr_bytes": len(completed.stderr),
            "stderr_sha256": sha256_bytes(completed.stderr),
            "stderr_tail": completed.stderr.decode("utf-8", errors="replace")[-500:],
        }
    )
    return completed


def beam_arguments() -> list[str]:
    roots = (
        REPO / "api" / "_build" / "test" / "lib",
        REPO / "api" / "_build" / "dev" / "lib",
        Path("/Volumes/SATECHI/github/barkpark/api/_build/test/lib"),
        Path("/Volumes/SATECHI/github/barkpark/api/_build/dev/lib"),
    )
    beam_root = next(
        (
            root
            for root in roots
            if (root / "barkpark" / "ebin").is_dir()
            and (root / "jason" / "ebin").is_dir()
        ),
        None,
    )
    if beam_root is None:
        raise RuntimeError("no precompiled Barkpark/Jason BEAM tree available")
    args: list[str] = []
    for ebin in sorted(beam_root.glob("*/ebin")):
        args.extend(["-pa", str(ebin)])
    return args


def candidate_schema(candidate_id: str, candidate: Mapping[str, Any], modules: Mapping[str, Any]) -> bool:
    if candidate_id == "PPCC2-E004":
        blocks = candidate.get("blocks")
        ids = [block.get("id") for block in blocks if isinstance(block, dict)]
        return bool(
            candidate.get("schema_version") == "portable-doc-candidate/v1"
            and isinstance(blocks, list)
            and all(
                isinstance(block, dict)
                and isinstance(block.get("type"), str)
                and block["type"]
                for block in blocks
            )
            and len(ids) == len(set(ids))
        )
    if candidate_id == "PPCC2-E005":
        return modules[candidate_id].validate(candidate) == []
    blocks = candidate["authored"]["portable_doc"]["blocks"]
    stats = modules[candidate_id].typed_tree_stats(blocks)
    return bool(
        candidate.get("schema_version") == modules[candidate_id].SCHEMA_VERSION
        and all(
            isinstance(block, dict)
            and isinstance(block.get("type"), str)
            and block["type"]
            for block in blocks
        )
        and stats["invalid_typed_nodes"] == 0
        and stats["max_json_depth"] <= 64
    )


def build_candidate(
    candidate_id: str,
    document: Mapping[str, Any],
    modules: Mapping[str, Any],
) -> dict[str, Any]:
    slug = str(document["_id"])
    if candidate_id == "PPCC2-E004":
        candidate, _ = modules[candidate_id].build_candidate(
            slug, {"result": copy.deepcopy(document)}
        )
        return candidate
    if candidate_id == "PPCC2-E005":
        return modules[candidate_id].build_candidate(copy.deepcopy(document))
    payload = {
        "id": slug,
        "_rev": document["_rev"],
        "title": document["title"],
        "source": {"kind": "blocks", "blocks": copy.deepcopy(document["blocks"])},
    }
    return modules[candidate_id].build_candidate(payload, f"paper:{slug}")


def render_python_candidate(
    module: Any, candidate: Mapping[str, Any]
) -> dict[str, tuple[bytes, bytes]]:
    outputs: dict[str, tuple[bytes, bytes]] = {}
    renderers = {
        "studio": module.render_studio,
        "tui80": lambda value: module.render_tui(value, 80),
        "tui40": lambda value: module.render_tui(value, 40),
        "email": module.render_email,
    }
    for surface, renderer in renderers.items():
        first = renderer(candidate).encode("utf-8")
        second = renderer(candidate).encode("utf-8")
        outputs[surface] = (first, second)
    cli = canonical_bytes(candidate)
    outputs["cli_api"] = (cli, canonical_bytes(json.loads(cli)))
    return outputs


def evaluate_case(
    candidate_id: str,
    document: Mapping[str, Any],
    modules: Mapping[str, Any],
    command_log: list[dict[str, Any]],
    elixir_args: Sequence[str],
) -> dict[str, Any]:
    slug = str(document["_id"])
    case_dir = CASES / candidate_id / slug
    case_dir.mkdir(parents=True, exist_ok=True)
    attacked = hostile_document(document)
    attacked_path = case_dir / "attacked-source.json"
    write_json(attacked_path, attacked)
    candidate = build_candidate(candidate_id, attacked, modules)
    candidate_path = case_dir / "candidate.json"
    candidate_path.write_bytes(canonical_bytes(candidate))

    outputs: dict[str, tuple[bytes, bytes]] = {}
    surface_commands: dict[str, list[list[str]]] = {}
    if candidate_id == "PPCC2-E006":
        outputs = render_python_candidate(modules[candidate_id], candidate)
        surface_commands = {
            surface: [[f"python:{candidate_id}.{surface}", str(candidate_path)]]
            for surface in REQUIRED_SURFACES
        }
    else:
        for surface in ("studio", "email"):
            rendered: list[bytes] = []
            surface_commands[surface] = []
            for repeat in (1, 2):
                command = [
                    "elixir",
                    *elixir_args,
                    str(HERE / "exact_render.exs"),
                    surface,
                    str(candidate_path),
                ]
                completed = run_command(command, command_log, cwd=HERE)
                surface_commands[surface].append(command)
                if completed.returncode != 0:
                    raise RuntimeError(
                        f"{candidate_id}/{slug}/{surface} failed: "
                        + completed.stderr.decode("utf-8", errors="replace")
                    )
                rendered.append(completed.stdout)
            outputs[surface] = (rendered[0], rendered[1])
        for width in (80, 40):
            surface = f"tui{width}"
            rendered = []
            surface_commands[surface] = []
            for repeat in (1, 2):
                command = [str(BIN / "pdrender"), str(candidate_path), str(width)]
                completed = run_command(command, command_log)
                surface_commands[surface].append(command)
                if completed.returncode != 0:
                    raise RuntimeError(
                        f"{candidate_id}/{slug}/{surface} failed: "
                        + completed.stderr.decode("utf-8", errors="replace")
                    )
                rendered.append(completed.stdout)
            outputs[surface] = (rendered[0], rendered[1])
        cli = canonical_bytes(candidate)
        outputs["cli_api"] = (cli, canonical_bytes(json.loads(cli)))
        surface_commands["cli_api"] = [["python:canonical-json-round-trip", str(candidate_path)]]

    output_paths: dict[str, Path] = {}
    for surface, (first, second) in outputs.items():
        suffix = "html" if surface in {"studio", "email"} else ("json" if surface == "cli_api" else "txt")
        first_path = case_dir / f"{surface}.1.{suffix}"
        first_path.write_bytes(first)
        (case_dir / f"{surface}.2.{suffix}").write_bytes(second)
        output_paths[surface] = first_path

    studio = outputs["studio"][0].decode("utf-8", errors="replace")
    email_output = outputs["email"][0].decode("utf-8", errors="replace")
    tui80 = outputs["tui80"][0].decode("utf-8", errors="replace")
    tui40 = outputs["tui40"][0].decode("utf-8", errors="replace")
    cli_api = outputs["cli_api"][0]
    studio_probe = probe_html(studio)
    email_probe = probe_html(email_output)
    width_metrics: dict[str, dict[str, int]] = {}
    for width in (80, 40):
        surface = f"tui{width}"
        command = [str(BIN / "widthcheck"), str(output_paths[surface]), str(width)]
        completed = run_command(command, command_log)
        if completed.returncode != 0:
            raise RuntimeError(
                f"{candidate_id}/{slug}/{surface} widthcheck failed: "
                + completed.stderr.decode("utf-8", errors="replace")
            )
        width_metrics[surface] = json.loads(completed.stdout)
    deterministic = {
        surface: sha256_bytes(pair[0]) == sha256_bytes(pair[1])
        for surface, pair in outputs.items()
    }
    safe_url_presence = {
        "studio": normalized(SAFE_URL) in normalized(studio),
        "tui80": normalized(SAFE_URL) in normalized(tui80),
        "tui40": normalized(SAFE_URL) in normalized(tui40),
        "email": normalized(SAFE_URL) in normalized(email_output),
        "cli_api": normalized(SAFE_URL)
        in normalized(cli_api.decode("utf-8", errors="replace")),
    }
    marker_presence = {
        "studio": markers_present(studio),
        "tui80": markers_present(tui80),
        "tui40": markers_present(tui40),
        "email": markers_present(email_output),
        "cli_api": markers_present(cli_api.decode("utf-8", errors="replace")),
    }
    marker_order = {
        "studio": markers_in_order(studio_probe["text"]),
        "tui80": markers_in_order(tui80),
        "tui40": markers_in_order(tui40),
        "email": markers_in_order(email_probe["text"]),
    }
    decoded = json.loads(cli_api.decode("utf-8"))
    cli_stable = canonical_bytes(decoded) == cli_api and decoded == candidate
    schema_valid = candidate_schema(candidate_id, candidate, modules)
    studio_pass = bool(
        studio_probe["h1_count"] == 1
        and marker_presence["studio"]
        and marker_order["studio"]
        and deterministic["studio"]
    )
    tui_pass = bool(
        width_metrics["tui80"]["overflow_lines"] == 0
        and width_metrics["tui40"]["overflow_lines"] == 0
        and deterministic["tui80"]
        and deterministic["tui40"]
    )
    email_pass = bool(
        email_probe["h1_count"] == 1
        and email_probe["script_count"] == 0
        and email_probe["details_count"] == 0
        and not email_probe["event_attributes"]
        and not email_probe["unsafe_url_attributes"]
        and marker_presence["email"]
        and marker_order["email"]
        and deterministic["email"]
    )
    accessibility_pass = bool(
        studio_probe["h1_count"] == 1
        and email_probe["h1_count"] == 1
        and studio_probe["images_missing_alt"] == 0
        and email_probe["images_missing_alt"] == 0
        and marker_order["studio"]
        and marker_order["email"]
    )
    content_pass = bool(
        all(marker_presence.values())
        and all(safe_url_presence.values())
        and all(marker_order.values())
    )
    hard_gates = {
        "portable_doc_schema_validity": schema_valid,
        "studio_structural_completeness": studio_pass,
        "tui_width": tui_pass,
        "email_safety": email_pass,
        "cli_api_round_trip": cli_stable and deterministic["cli_api"],
        "accessibility": accessibility_pass,
        "content_preservation": content_pass,
    }
    return {
        "candidate_id": candidate_id,
        "unit_id": f"paper:{slug}",
        "document_rev": document["_rev"],
        "attacked_block_count": len(attacked["blocks"]),
        "hard_gate_pass": all(hard_gates.values()),
        "hard_gates": hard_gates,
        "portable_doc_schema_validity": {"pass": schema_valid},
        "studio_structural_completeness": {
            "pass": studio_pass,
            "logical_h1_count": studio_probe["h1_count"],
            "markers_present": marker_presence["studio"],
            "attack_order_preserved": marker_order["studio"],
        },
        "tui_width": {
            "pass": tui_pass,
            "tui80_max_display_width": width_metrics["tui80"]["max_display_width"],
            "tui80_overflow_lines": width_metrics["tui80"]["overflow_lines"],
            "tui40_max_display_width": width_metrics["tui40"]["max_display_width"],
            "tui40_overflow_lines": width_metrics["tui40"]["overflow_lines"],
        },
        "email_safety": {
            "pass": email_pass,
            "logical_h1_count": email_probe["h1_count"],
            "script_count": email_probe["script_count"],
            "details_count": email_probe["details_count"],
            "event_attributes": email_probe["event_attributes"],
            "unsafe_url_attributes": email_probe["unsafe_url_attributes"],
            "markers_present": marker_presence["email"],
            "attack_order_preserved": marker_order["email"],
        },
        "cli_api_round_trip": {
            "pass": cli_stable and deterministic["cli_api"],
            "canonical_sha256": sha256_bytes(cli_api),
            "decode_encode_byte_stable": cli_stable,
        },
        "accessibility": {
            "pass": accessibility_pass,
            "studio_logical_h1_count": studio_probe["h1_count"],
            "email_logical_h1_count": email_probe["h1_count"],
            "studio_images_missing_alt": studio_probe["images_missing_alt"],
            "email_images_missing_alt": email_probe["images_missing_alt"],
            "deterministic_reading_order": marker_order["studio"] and marker_order["email"],
        },
        "content_preservation": {
            "pass": content_pass,
            "marker_presence": marker_presence,
            "safe_url_presence": safe_url_presence,
            "attack_order": marker_order,
        },
        "determinism": deterministic,
        "surface_commands": surface_commands,
        "artifact_directory": str(case_dir.relative_to(HERE)),
        "candidate_sha256": sha256_file(candidate_path),
    }


def aggregate(results: Sequence[Mapping[str, Any]], elapsed: float) -> dict[str, Any]:
    total = len(results)

    def gate(name: str) -> dict[str, Any]:
        passed = sum(bool(result["hard_gates"][name]) for result in results)
        return {
            "passed": passed,
            "attempted": total,
            "pass_rate": round(passed / total, 6) if total else 0.0,
            "pass": passed == total and total > 0,
        }

    per_candidate: dict[str, Any] = {}
    for candidate_id in CANDIDATE_IDS:
        subset = [result for result in results if result["candidate_id"] == candidate_id]
        hard_cells = len(subset) * 7
        hard_passes = sum(
            sum(bool(value) for value in result["hard_gates"].values())
            for result in subset
        )
        per_candidate[candidate_id] = {
            "units_attempted": len(subset),
            "units_passing_all_hard_gates": sum(
                bool(result["hard_gate_pass"]) for result in subset
            ),
            "hard_checks_passed": hard_passes,
            "hard_checks_total": hard_cells,
            "observed_failure_rate": round(
                (hard_cells - hard_passes) / hard_cells, 6
            )
            if hard_cells
            else 0.0,
        }

    hard_cells = total * 7
    hard_passes = sum(
        sum(bool(value) for value in result["hard_gates"].values())
        for result in results
    )
    passing_batches = [
        summary["units_passing_all_hard_gates"]
        for summary in per_candidate.values()
    ]
    return {
        "portable_doc_schema_validity": gate("portable_doc_schema_validity"),
        "studio_structural_completeness": gate("studio_structural_completeness"),
        "tui_width": {
            **gate("tui_width"),
            "tui80_max_display_width": max(
                result["tui_width"]["tui80_max_display_width"] for result in results
            ),
            "tui40_max_display_width": max(
                result["tui_width"]["tui40_max_display_width"] for result in results
            ),
            "overflow_lines_total": sum(
                result["tui_width"]["tui80_overflow_lines"]
                + result["tui_width"]["tui40_overflow_lines"]
                for result in results
            ),
        },
        "email_safety": gate("email_safety"),
        "cli_api_round_trip": gate("cli_api_round_trip"),
        "accessibility": gate("accessibility"),
        "content_preservation": gate("content_preservation"),
        "pilot_gate_pass_rate": {
            "applicable": False,
            "value": None,
            "reason": "PPCC2-E008 is Round 3 attack; Round 5 pilot was not started.",
        },
        "observed_failure_rate": {
            "hard_failures": hard_cells - hard_passes,
            "hard_checks": hard_cells,
            "rate": round((hard_cells - hard_passes) / hard_cells, 6)
            if hard_cells
            else 0.0,
        },
        "batch_capacity": {
            "units_per_candidate_attempted": UNIT_COUNT,
            "surface_projections_per_unit": len(REQUIRED_SURFACES),
            "largest_disjoint_candidate_batch_completing_all_round3_hard_gates": max(
                passing_batches
            ),
            "provisional_only": True,
            "reason": "Only the Round 5 pilot may seal builder batch capacity.",
            "wall_seconds": round(elapsed, 6),
        },
        "rollback": {
            "pass": True,
            "production_mutations": 0,
            "rule": "discard the isolated PPCC2-E008 assignment directory",
        },
        "by_candidate": per_candidate,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("run",))
    args = parser.parse_args()
    if args.command != "run":
        return 2

    started = time.monotonic()
    command_log: list[dict[str, Any]] = []
    modules = {
        "PPCC2-E004": load_module(
            "ppcc2_e004", INPUTS / "PPCC2-E004" / "run_candidate.py"
        ),
        "PPCC2-E005": load_module(
            "ppcc2_e005", INPUTS / "PPCC2-E005" / "candidate_lab.py"
        ),
        "PPCC2-E006": load_module(
            "ppcc2_e006", INPUTS / "PPCC2-E006" / "candidate.py"
        ),
    }
    documents = json.loads(
        (INPUTS / "PPCC2-E005" / "source-fixtures.json").read_text(
            encoding="utf-8"
        )
    )["documents"]
    if len(documents) != UNIT_COUNT:
        raise RuntimeError(f"expected {UNIT_COUNT} fixtures, found {len(documents)}")

    BIN.mkdir(parents=True, exist_ok=True)
    build = run_command(
        [
            "go",
            "build",
            "-o",
            str(BIN / "pdrender"),
            "./internal/pdrender/cmd/dump",
        ],
        command_log,
    )
    if build.returncode != 0:
        raise RuntimeError(
            "pdrender build failed: "
            + build.stderr.decode("utf-8", errors="replace")
        )
    widthcheck_build = run_command(
        [
            "go",
            "build",
            "-o",
            str(BIN / "widthcheck"),
            "./internal/pdrender/cmd/widthcheck",
        ],
        command_log,
    )
    if widthcheck_build.returncode != 0:
        raise RuntimeError(
            "widthcheck build failed: "
            + widthcheck_build.stderr.decode("utf-8", errors="replace")
        )
    elixir_args = beam_arguments()
    results: list[dict[str, Any]] = []
    for candidate_id in CANDIDATE_IDS:
        for document in documents:
            results.append(
                evaluate_case(
                    candidate_id,
                    document,
                    modules,
                    command_log,
                    elixir_args,
                )
            )

    elapsed = time.monotonic() - started
    metrics = aggregate(results, elapsed)
    write_json(COMMAND_LOG, command_log)
    run_summary = {
        "schema_version": "ppcc2-e008-run-summary/v1",
        "assignment_id": ASSIGNMENT_ID,
        "candidate_count": len(CANDIDATE_IDS),
        "fixture_count": UNIT_COUNT,
        "case_count": len(results),
        "required_surfaces": list(REQUIRED_SURFACES),
        "metrics": metrics,
        "fixture_results": results,
        "command_log": str(COMMAND_LOG.relative_to(HERE)),
        "command_count": len(command_log),
    }
    write_json(RUN_SUMMARY, run_summary)
    print(
        json.dumps(
            {
                "assignment_id": ASSIGNMENT_ID,
                "candidates": len(CANDIDATE_IDS),
                "fixtures": UNIT_COUNT,
                "cases": len(results),
                "hard_failures": metrics["observed_failure_rate"]["hard_failures"],
                "observed_failure_rate": metrics["observed_failure_rate"]["rate"],
                "by_candidate": metrics["by_candidate"],
                "wall_seconds": round(elapsed, 6),
                "run_summary_sha256": sha256_file(RUN_SUMMARY),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
