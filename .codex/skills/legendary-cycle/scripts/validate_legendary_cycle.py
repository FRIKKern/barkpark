#!/usr/bin/env python3
"""Validate the machine-checkable Barkpark Legendary Cycle preflight contract."""

from __future__ import annotations

import importlib.util
import html
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, quote, urlsplit


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
B1_SCOPE_FENCE_VERSION = "b1-scope-fence-v1"
B1_SCOPE_FENCE_KEYS = {
    "version",
    "workspace_id",
    "project_id",
    "epic_id",
    "wave_id",
    "wave_revision",
    "inventory_digest",
    "plan_digest",
    "reconciliation_digest",
    "fleet_digest",
    "receipt_digest",
}

RELEASE_GATE_FORMAT = "cycle-release-gate-v1"
RELEASE_BUNDLE_FORMAT = "cycle-release-evidence-bundle-v1"
RELEASE_COUNTS = {
    "inventory_count": 503,
    "assigned_count": 503,
    "shipped_count": 42,
    "stalled_count": 291,
    "excluded_count": 170,
}
RELEASE_AUTHORITY_FORMATS = {
    "queue_gate": "queue-gate-v1",
    "ordering": "closure-nearest-order-v1",
    "semantic_receipt": "semantic_receipt-index-v1",
    "correction_of": "correction_of-v1",
    "b1_scope": "b1-scope-fence-v1",
    "quarantine": "quarantine-promotion-v1",
    "promotion": "quarantine-promotion-v1",
}
RELEASE_READER_SURFACES = ("source_json", "public_html", "cli", "task_board", "tui")
RELEASE_DEFECT_LISTS = (
    "duplicate_assignment_unit_ids",
    "unknown_assignment_unit_ids",
    "unknown_outcome_unit_ids",
    "outcome_overlap_unit_ids",
    "outcome_ownership_violation_unit_ids",
    "invalid_build_assignment_ids",
    "invalid_build_result_assignment_ids",
    "unassigned_unit_ids",
    "unaccounted_unit_ids",
)


class ReleaseGateError(ValueError):
    """A fail-closed release artifact validation error."""


def _release_require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseGateError(message)


def _release_digest(value: Any) -> str:
    return EPIC.canonical_digest(value)


def _release_paper_identity(paper: dict[str, Any]) -> tuple[str, str]:
    doc = paper.get("doc") if isinstance(paper.get("doc"), dict) else paper
    paper_id = doc.get("doc_id") or doc.get("_id") or doc.get("id")
    revision = doc.get("rev") or doc.get("_rev") or doc.get("revision")
    _release_require(EPIC.nonempty_string(paper_id), "Paper identity is missing")
    _release_require(EPIC.nonempty_string(revision), f"Paper {paper_id} immutable revision is missing")
    _release_require(str(revision).casefold() != "latest", f"Paper {paper_id} revision cannot be latest")
    return str(paper_id), str(revision)


def _release_paper_blocks(paper: dict[str, Any]) -> list[dict[str, Any]]:
    blocks = EPIC.paper_blocks(EPIC.paper_doc(paper))
    _release_require(isinstance(blocks, list) and bool(blocks), "Paper has no meaningful block source")
    _release_require(all(isinstance(block, dict) for block in blocks), "Paper blocks are not objects")
    return blocks


def _release_paper_authority(
    role: str,
    paper: dict[str, Any],
    live_ledger: dict[str, Any],
    live_fleet: dict[str, Any],
) -> dict[str, Any]:
    paper_id, revision = _release_paper_identity(paper)
    blocks = _release_paper_blocks(paper)
    matches = [
        block
        for block in blocks
        if block.get("cycle_ledger") == live_ledger and block.get("fleet") == live_fleet
    ]
    _release_require(
        len(matches) == 1,
        f"{role} Paper must contain exactly one live cycle_ledger/fleet authority block",
    )

    doc = paper.get("doc") if isinstance(paper.get("doc"), dict) else paper
    for field, expected in (("cycle_ledger", live_ledger), ("fleet", live_fleet)):
        if field in doc:
            _release_require(doc[field] == expected, f"{role} Paper top-level {field} drifted")

    return {
        "id": paper_id,
        "revision": revision,
        "content_digest": _release_digest(blocks),
    }


def _release_prior_authorities(
    authorities: dict[str, Any], cycle_authority: dict[str, Any]
) -> dict[str, str]:
    _release_require(
        set(authorities) == set(RELEASE_AUTHORITY_FORMATS),
        "prior-authorities manifest has an invalid exact shape",
    )
    result: dict[str, str] = {}
    for name, expected_format in RELEASE_AUTHORITY_FORMATS.items():
        receipt = authorities.get(name)
        _release_require(isinstance(receipt, dict), f"{name} authority receipt is not an object")
        _release_require(receipt.get("format") == expected_format, f"{name} authority format mismatch")
        _release_require(
            receipt.get("epic_id") == cycle_authority.get("epic_id"),
            f"{name} authority epic scope mismatch",
        )
        _release_require(
            receipt.get("wave_revision") == cycle_authority.get("wave_revision"),
            f"{name} authority wave revision mismatch",
        )
        digest = receipt.get("receipt_digest")
        _release_require(
            isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
            f"{name} authority receipt digest is invalid",
        )
        unsigned = {key: value for key, value in receipt.items() if key != "receipt_digest"}
        _release_require(digest == _release_digest(unsigned), f"{name} authority receipt digest mismatch")
        result[name] = digest
    return result


def _release_cycle(cycle: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    ledger = cycle.get("cycle_ledger")
    fleet = cycle.get("fleet")
    authority = cycle.get("authority")
    lifecycle = cycle.get("correction_lifecycle")
    _release_require(isinstance(ledger, dict), "live Cycle has no cycle_ledger")
    _release_require(isinstance(fleet, dict) and bool(fleet), "live Cycle has no fleet")
    _release_require(isinstance(authority, dict), "live Cycle has no authority")
    _release_require(authority.get("kind") == "barkpark_cycle_fleet", "live Cycle authority kind mismatch")
    for field in ("workspace_slug", "project_slug"):
        _release_require(
            EPIC.nonempty_string(authority.get(field)),
            f"live Cycle authority {field} is invalid",
        )
    canonical_origin = urlsplit(str(authority.get("canonical_origin", "")))
    _release_require(
        canonical_origin.scheme in {"http", "https"}
        and bool(canonical_origin.netloc)
        and canonical_origin.username is None
        and canonical_origin.password is None
        and canonical_origin.path in {"", "/"}
        and not canonical_origin.query
        and not canonical_origin.fragment,
        "live Cycle canonical origin is invalid",
    )
    _release_require(isinstance(lifecycle, dict), "live Cycle has no correction_lifecycle")
    for field, expected in RELEASE_COUNTS.items():
        _release_require(ledger.get(field) == expected, f"live Cycle {field} must equal {expected}")
    _release_require(ledger.get("exact") is True, "live Cycle exact flag is not true")
    _release_require(ledger.get("fleet_complete") is True, "live Cycle fleet is not complete")
    for field in RELEASE_DEFECT_LISTS:
        _release_require(ledger.get(field) == [], f"live Cycle {field} is not empty")
    for field in ("reconciliation_digest", "correction_of_digest", "correction_receipt_digest"):
        _release_require(
            isinstance(ledger.get(field), str)
            and re.fullmatch(r"[0-9a-f]{64}", ledger[field]) is not None,
            f"live Cycle {field} is invalid",
        )

    current = lifecycle.get("current")
    superseded = lifecycle.get("superseded")
    _release_require(isinstance(current, dict), "release Cycle has no current correction")
    target_revision = authority.get("wave_revision")
    ancestry = lifecycle.get("historical_ancestry")
    target_is_current = current.get("wave_revision") == target_revision
    target_is_candidate = isinstance(ancestry, list) and any(
        isinstance(row, dict) and row.get("wave_revision") == target_revision for row in ancestry
    )
    _release_require(
        target_is_current or target_is_candidate,
        "Cycle authority is neither the current nor a linked candidate correction",
    )
    quarantines = lifecycle.get("quarantines")
    _release_require(isinstance(quarantines, list), "release Cycle quarantines are invalid")
    _release_require(
        not any(
            isinstance(row, dict) and row.get("target_wave_revision") == target_revision
            for row in quarantines
        ),
        "release candidate is quarantined",
    )
    _release_require(isinstance(lifecycle.get("promotion"), dict), "release Cycle has no promotion authority")
    _release_require(
        isinstance(lifecycle.get("authority_evidence"), dict),
        "release Cycle has no immutable promotion admission",
    )
    _release_require(isinstance(superseded, list) and bool(superseded), "release Cycle has no superseded evidence")
    historical = next(
        (
            row
            for row in superseded
            if isinstance(row, dict)
            and isinstance(row.get("semantic_snapshot"), dict)
            and row["semantic_snapshot"].get("shipped_count") == 53
            and row["semantic_snapshot"].get("stalled_count") == 280
            and row["semantic_snapshot"].get("excluded_count") == 170
        ),
        None,
    )
    _release_require(historical is not None, "superseded Wave 3 semantic snapshot 53/280/170 is missing")
    delta = historical.get("delta")
    _release_require(
        isinstance(delta, dict)
        and delta.get("shipped") == -11
        and delta.get("stalled") == 11
        and delta.get("excluded") == 0,
        "superseded Wave 3 -11/+11 correction delta is missing",
    )
    scope_fields = ("workspace_id", "project_id", "epic_id", "wave_id", "wave_revision")
    for field in scope_fields:
        _release_require(EPIC.nonempty_string(authority.get(field)), f"Cycle authority {field} is empty")
    markers = [
        "candidate" if target_is_candidate and not target_is_current else "current",
        str(authority["wave_id"]),
        str(target_revision),
        "current",
        str(current.get("wave_id", "")),
        str(current.get("wave_revision", "")),
        "503",
        "42",
        "291",
        "170",
        "superseded",
        str(historical.get("wave_id", "wave 3")),
        "53",
        "280",
        "-11",
        "+11",
    ]
    return {
        "inventory_count": 503,
        "assigned_count": 503,
        "shipped_count": 42,
        "stalled_count": 291,
        "excluded_count": 170,
        "reconciliation_digest": ledger["reconciliation_digest"],
        "fleet_digest": _release_digest(fleet),
        "correction_lifecycle_digest": _release_digest(lifecycle),
        "candidate_state": "current" if target_is_current else "candidate",
    }, markers


def _release_visible_text(raw: bytes, capture_name: str) -> str:
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ReleaseGateError(f"{capture_name} capture is not UTF-8") from error
    if "html" in capture_name:
        decoded = html.unescape(re.sub(r"<[^>]+>", " ", decoded))
    return " ".join(decoded.split()).casefold()


def _release_reader_capture(
    role: str,
    surface: str,
    capture: dict[str, Any],
    paper: dict[str, Any],
    paper_pin: dict[str, Any],
    gate_digest: str,
    gate_id: str,
    wave_revision: str,
    cycle_authority: dict[str, Any],
    expected_projection: dict[str, Any],
    markers: list[str],
) -> None:
    _release_require(
        set(capture)
        == {
            "producer",
            "gate_id",
            "challenge_id",
            "capture_id",
            "address",
            "document_id",
            "revision",
            "content_digest",
            "gate_digest",
            "raw",
            "normalized_projection",
        },
        f"{role} {surface} capture has an invalid exact shape",
    )
    _release_require(
        capture["producer"] == "barkpark-server-capture-v1",
        f"{role} {surface} is not a stored server capture",
    )
    for field in ("gate_id", "challenge_id", "capture_id"):
        _release_require(
            EPIC.nonempty_string(capture[field]) and str(capture[field]).casefold() != "latest",
            f"{role} {surface} {field} is invalid",
        )
    _release_require(capture["document_id"] == paper_pin["id"], f"{role} {surface} document drifted")
    _release_require(capture["revision"] == paper_pin["revision"], f"{role} {surface} revision drifted")
    _release_require(
        capture["content_digest"] == paper_pin["content_digest"],
        f"{role} {surface} content digest drifted",
    )
    _release_require(capture["gate_digest"] == gate_digest, f"{role} {surface} gate digest drifted")
    address = capture["address"]
    _release_require(EPIC.nonempty_string(address), f"{role} {surface} address is empty")
    parsed = urlsplit(address)
    canonical_origin = urlsplit(cycle_authority["canonical_origin"])
    route = "render" if surface == "public_html" else "source"
    expected_path = (
        f"/w/{quote(str(cycle_authority['workspace_slug']), safe='')}"
        f"/p/{quote(str(cycle_authority['project_slug']), safe='')}"
        f"/v1/cycles/{quote(str(cycle_authority['epic_id']), safe='')}"
        f"/{quote(str(cycle_authority['wave_id']), safe='')}"
        f"/release-gates/{quote(gate_id, safe='')}/papers/{quote(role, safe='')}/{route}"
    )
    _release_require(
        parsed.scheme == canonical_origin.scheme
        and parsed.netloc == canonical_origin.netloc
        and parsed.username is None
        and parsed.password is None
        and not parsed.fragment
        and parsed.path == expected_path
        and parse_qs(parsed.query, strict_parsing=True)
        == {
            "candidate_id": [paper_pin["revision"]],
            "wave_revision": [wave_revision],
        },
        f"{role} {surface} is not revision/gate addressed",
    )
    _release_require(
        capture["normalized_projection"] == expected_projection,
        f"{role} {surface} normalized projection drifted",
    )
    raw = capture["raw"]
    if surface == "source_json":
        _release_require(isinstance(raw, dict), f"{role} source_json raw capture is not an object")
        source_id = raw.get("id") or raw.get("_id")
        source_revision = raw.get("_rev") or raw.get("rev")
        source_arm = raw.get("source")
        _release_require(source_id == paper_pin["id"], f"{role} source_json identity drifted")
        _release_require(source_revision == paper_pin["revision"], f"{role} source_json revision drifted")
        _release_require(
            isinstance(source_arm, dict)
            and source_arm.get("kind") == "blocks"
            and source_arm.get("blocks") == _release_paper_blocks(paper),
            f"{role} source_json blocks drifted from immutable Paper",
        )
    else:
        _release_require(isinstance(raw, str), f"{role} {surface} raw capture is not text")
        visible = _release_visible_text(raw.encode("utf-8"), surface)
        _release_require(
            len(re.sub(r"[^\w]+", "", visible, flags=re.UNICODE)) >= 32,
            f"{role} {surface} capture is not meaningful",
        )
        missing = [marker for marker in markers if marker.casefold() not in visible]
        _release_require(
            not missing,
            f"{role} {surface} capture is missing markers: {', '.join(missing)}",
        )


def build_release_gate_bundle(stage: str, evidence: dict[str, Any]) -> dict[str, Any]:
    """Validate and retain the complete raw evidence used by one release gate."""
    _release_require(stage in {"open", "activate"}, "release stage must be open or activate")
    _release_require(
        set(evidence)
        == {
            "gate_id",
            "challenge_id",
            "gate_digest",
            "proposed_successor",
            "cycle",
            "cycle_cli",
            "prior_authorities",
            "papers",
            "readers",
        },
        "release evidence has an invalid exact shape",
    )
    cycle = evidence["cycle"]
    _release_require(isinstance(cycle, dict), "release Cycle evidence is not an object")
    _release_require(evidence["cycle_cli"] == cycle, "cycle_cli drifted from actual live Cycle")
    cycle_record, markers = _release_cycle(cycle)
    if stage == "open":
        _release_require(cycle_record["candidate_state"] == "current", "open gate must target current Cycle")
        _release_require(evidence["gate_digest"] is None, "open gate digest must be null")
        _release_require(evidence["gate_id"] is None, "open gate id must be null")
        _release_require(evidence["challenge_id"] is None, "open challenge id must be null")
    else:
        _release_require(
            isinstance(evidence["gate_digest"], str)
            and re.fullmatch(r"[0-9a-f]{64}", evidence["gate_digest"]) is not None,
            "activate gate digest is invalid",
        )
        for field in ("gate_id", "challenge_id"):
            _release_require(
                EPIC.nonempty_string(evidence[field]) and str(evidence[field]).casefold() != "latest",
                f"activate {field} is invalid",
            )

    proposed = evidence["proposed_successor"]
    _release_require(
        isinstance(proposed, dict)
        and set(proposed)
        == {"epic_id", "wave_id", "profile", "inventory_digest", "plan_digest", "correction_of_digest"},
        "proposed successor has an invalid exact shape",
    )
    _release_require(proposed["epic_id"] == cycle["authority"]["epic_id"], "proposed successor epic drifted")
    _release_require(proposed["profile"] == "legendary", "proposed successor profile is not legendary")
    for field in ("inventory_digest", "plan_digest", "correction_of_digest"):
        _release_require(
            isinstance(proposed[field], str) and re.fullmatch(r"[0-9a-f]{64}", proposed[field]) is not None,
            f"proposed successor {field} is invalid",
        )
    _release_require(
        proposed["inventory_digest"] == cycle["cycle_ledger"].get("inventory_digest"),
        "proposed successor inventory digest drifted",
    )
    if stage == "open":
        _release_require(
            proposed["wave_id"] != cycle["authority"]["wave_id"],
            "proposed successor wave must differ from current wave",
        )
    else:
        _release_require(
            proposed["wave_id"] == cycle["authority"]["wave_id"]
            and proposed["correction_of_digest"] == cycle["cycle_ledger"].get("correction_of_digest"),
            "live candidate does not match proposed successor contract",
        )

    papers = evidence["papers"]
    _release_require(
        isinstance(papers, dict) and set(papers) == {"campaign", "successor"},
        "release Papers have an invalid exact shape",
    )
    campaign = papers["campaign"]
    _release_require(isinstance(campaign, dict), "campaign Paper is missing")
    paper_records: dict[str, Any] = {
        "campaign": _release_paper_authority(
            "campaign", campaign, cycle["cycle_ledger"], cycle["fleet"]
        ),
        "successor": None,
    }

    if stage == "open":
        _release_require(papers["successor"] is None, "open evidence successor Paper must be null")
        _release_require(evidence["readers"] is None, "open evidence readers must be null")
        readers_digest = None
    else:
        successor = papers["successor"]
        _release_require(isinstance(successor, dict), "activate evidence successor Paper is missing")
        paper_records["successor"] = _release_paper_authority(
            "successor", successor, cycle["cycle_ledger"], cycle["fleet"]
        )
        _release_require(
            paper_records["campaign"]["id"] != paper_records["successor"]["id"]
            and paper_records["campaign"]["revision"] != paper_records["successor"]["revision"],
            "campaign and successor Paper identities and revisions must differ",
        )
        readers = evidence["readers"]
        _release_require(
            isinstance(readers, dict) and set(readers) == {"campaign", "successor"},
            "activate readers have an invalid exact role shape",
        )
        expected_projection = {
            "cycle_ledger": cycle["cycle_ledger"],
            "fleet": cycle["fleet"],
            "correction_context": cycle["correction_lifecycle"],
        }
        capture_ids: set[str] = set()
        for role, paper in (("campaign", campaign), ("successor", successor)):
            captures = readers[role]
            _release_require(
                isinstance(captures, dict) and set(captures) == set(RELEASE_READER_SURFACES),
                f"{role} readers have an invalid exact surface shape",
            )
            for surface in RELEASE_READER_SURFACES:
                _release_require(
                    isinstance(captures[surface], dict), f"{role} {surface} capture is not an object"
                )
                _release_reader_capture(
                    role,
                    surface,
                    captures[surface],
                    paper,
                    paper_records[role],
                    evidence["gate_digest"],
                    evidence["gate_id"],
                    cycle["authority"]["wave_revision"],
                    cycle["authority"],
                    expected_projection,
                    markers,
                )
                _release_require(
                    captures[surface]["gate_id"] == evidence["gate_id"]
                    and captures[surface]["challenge_id"] == evidence["challenge_id"],
                    f"{role} {surface} server capture challenge drifted",
                )
                capture_id = captures[surface]["capture_id"]
                _release_require(
                    capture_id not in capture_ids,
                    f"{role} {surface} reuses server capture id {capture_id}",
                )
                capture_ids.add(capture_id)
        readers_digest = _release_digest(readers)

    authority = {
        field: cycle["authority"][field]
        for field in (
            "workspace_id",
            "workspace_slug",
            "project_id",
            "project_slug",
            "canonical_origin",
            "epic_id",
            "wave_id",
            "wave_revision",
        )
    }
    receipt = {
        "format": RELEASE_GATE_FORMAT,
        "stage": stage,
        "authority": authority,
        "cycle": cycle_record,
        "authorities": _release_prior_authorities(evidence["prior_authorities"], cycle["authority"]),
        "papers": paper_records,
        "gate_id": evidence["gate_id"],
        "challenge_id": evidence["challenge_id"],
        "proposed_successor_digest": _release_digest(proposed),
        "readers_digest": readers_digest,
        "evidence_digest": _release_digest(evidence),
    }
    receipt["receipt_digest"] = _release_digest(receipt)
    return {
        "format": RELEASE_BUNDLE_FORMAT,
        "stage": stage,
        "purpose": "non-authoritative-preflight",
        "evidence": evidence,
        "receipt": receipt,
    }


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
) -> tuple[
    dict[str, Any] | None,
    dict[str, Any] | None,
    dict[str, Any] | None,
]:
    if getattr(args, "cycle_json", None):
        payload = EPIC.load_json(args.cycle_json)
    else:
        scope = paper_ledger.get("scope")
        if not isinstance(scope, dict):
            return None, None, None
        epic_id = scope.get("epic_id")
        wave_id = scope.get("wave_id")
        if not EPIC.nonempty_string(epic_id) or not EPIC.nonempty_string(wave_id):
            return None, None, None
        workspace = getattr(args, "workspace", None)
        project = getattr(args, "project", None)
        if not EPIC.nonempty_string(workspace) or not EPIC.nonempty_string(project):
            return None, None, None
        payload = EPIC.command_json(
            "bp", "--workspace", workspace, "--project", project,
            "cycle", "show", epic_id, wave_id, "-o", "json"
        )
    ledger = payload.get("cycle_ledger") if isinstance(payload, dict) else None
    fleet = payload.get("fleet") if isinstance(payload, dict) else None
    authority = payload.get("authority") if isinstance(payload, dict) else None
    return (
        ledger if isinstance(ledger, dict) else None,
        fleet if isinstance(fleet, dict) else None,
        authority if isinstance(authority, dict) else None,
    )


def validate_b1_scope_fence(
    args: Any,
    live_ledger: dict[str, Any] | None,
    live_fleet: dict[str, Any] | None,
    live_authority: dict[str, Any] | None,
) -> list[str]:
    """Bind Legendary B1 bytes to the already-resolved live Cycle authority."""
    if args.phase not in {"build", "review"}:
        return []
    ledger_path = getattr(args, "fleet_ledger_json", None)
    if ledger_path is None:
        return []
    try:
        b1 = EPIC.load_canonical_ledger(ledger_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        # The shared validator owns canonical-byte/shape diagnostics.
        return []

    if live_ledger is None or live_fleet is None or live_authority is None:
        return ["cannot validate B1 scope fence without the live Cycle authority"]

    manifest = b1.get("manifest")
    fence = manifest.get("cycle_scope_fence") if isinstance(manifest, dict) else None
    if not isinstance(fence, dict):
        return ["Legendary B1 manifest has no cycle_scope_fence"]
    if set(fence) != B1_SCOPE_FENCE_KEYS:
        return ["Legendary B1 cycle_scope_fence has an invalid exact shape"]

    errors: list[str] = []
    unsigned = {key: value for key, value in fence.items() if key != "receipt_digest"}
    if fence.get("version") != B1_SCOPE_FENCE_VERSION:
        errors.append(f"Legendary B1 cycle_scope_fence version is not {B1_SCOPE_FENCE_VERSION}")
    if fence.get("receipt_digest") != EPIC.canonical_digest(unsigned):
        errors.append("Legendary B1 cycle_scope_fence receipt_digest mismatch")

    if live_authority.get("kind") != "barkpark_cycle_fleet":
        errors.append("live Cycle authority kind is not barkpark_cycle_fleet")

    authority_scope = {
        "workspace_id": live_authority.get("workspace_id"),
        "project_id": live_authority.get("project_id"),
        "epic_id": live_authority.get("epic_id"),
        "wave_id": live_authority.get("wave_id"),
        "wave_revision": live_authority.get("wave_revision"),
    }
    ledger_scope = live_ledger.get("scope")
    if not isinstance(ledger_scope, dict):
        errors.append("live Cycle ledger has no scope for the B1 fence")
        ledger_scope = {}
    expected = {
        **authority_scope,
        "inventory_digest": live_ledger.get("inventory_digest"),
        "plan_digest": live_ledger.get("plan_digest"),
        "reconciliation_digest": live_ledger.get("reconciliation_digest"),
        "fleet_digest": EPIC.canonical_digest(live_fleet),
    }
    for field, expected_value in expected.items():
        if not EPIC.nonempty_string(expected_value):
            errors.append(f"live Cycle authority {field} is empty or invalid for the B1 fence")
        elif fence.get(field) != expected_value:
            errors.append(f"Legendary B1 cycle_scope_fence {field} does not match live Cycle authority")

    for field in ("workspace_id", "project_id", "epic_id", "wave_id"):
        if ledger_scope.get(field) != authority_scope[field]:
            errors.append(f"live Cycle authority and ledger scope disagree on {field}")
    if live_ledger.get("wave_revision") != authority_scope["wave_revision"]:
        errors.append("live Cycle authority and ledger disagree on wave_revision")

    experiment = b1.get("experiment")
    if not isinstance(experiment, dict):
        return errors
    for field in ("workspace_id", "epic_id", "wave_id"):
        if experiment.get(field) != authority_scope[field]:
            errors.append(f"Legendary B1 experiment {field} does not match live Cycle authority")

    attempts = b1.get("attempts")
    if isinstance(attempts, list):
        for index, attempt in enumerate(attempts, start=1):
            attempt_id = attempt.get("attempt_id") if isinstance(attempt, dict) else None
            label = attempt_id if EPIC.nonempty_string(attempt_id) else f"#{index}"
            provenance = attempt.get("provenance") if isinstance(attempt, dict) else None
            if not isinstance(provenance, dict) or provenance.get("scope_receipt_digest") != fence.get(
                "receipt_digest"
            ):
                errors.append(
                    f"Legendary B1 attempt {label} provenance scope_receipt_digest "
                    "does not match the Cycle scope fence"
                )
            if not isinstance(provenance, dict) or provenance.get("wave_revision") != fence.get(
                "wave_revision"
            ):
                errors.append(
                    f"Legendary B1 attempt {label} provenance wave_revision "
                    "does not match the Cycle scope fence"
                )
    return errors


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


_EPIC_VALIDATE_LEDGER = EPIC.validate_ledger


def validate_scope_fenced_ledger(
    ledger: dict[str, Any],
    paper: dict[str, Any],
    task_parent_id: Any,
    paper_id: str,
) -> list[str]:
    """Validate Legendary B1 scope against its live-bound Cycle fence.

    The shared Epic validator normally binds a B1 to the task's parent epic.
    A Legendary root campaign can instead open CycleFleet with the claimed
    task itself as the immutable epic authority. The Legendary fence is later
    reconciled field-for-field against that live authority, so use its epic id
    for the shared structural check rather than inventing parent-goal scope.
    """
    manifest = ledger.get("manifest")
    fence = manifest.get("cycle_scope_fence") if isinstance(manifest, dict) else None
    expected_epic_id = (
        fence.get("epic_id")
        if isinstance(fence, dict) and EPIC.nonempty_string(fence.get("epic_id"))
        else task_parent_id
    )
    return _EPIC_VALIDATE_LEDGER(ledger, paper, expected_epic_id, paper_id)


EPIC.validate_fleet = validate_fleet
EPIC.validate_ledger = validate_scope_fenced_ledger


def validate(args: Any) -> list[str]:
    errors = EPIC.validate(args)
    paper = EPIC.paper_doc(EPIC.load_json(args.paper_json)) if args.paper_json else EPIC.paper_doc(
        EPIC.command_json("bp", "doc", "get", "paper", args.paper, "-o", "json")
    )
    errors.extend(validate_scale(paper))
    paper_ledger = _cycle_ledger(paper)
    live_ledger, live_fleet, live_authority = (
        _live_cycle_projection(args, paper_ledger) if paper_ledger else (None, None, None)
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
    errors.extend(validate_b1_scope_fence(args, live_ledger, live_fleet, live_authority))
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
