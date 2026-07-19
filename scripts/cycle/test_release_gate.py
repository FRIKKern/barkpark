#!/usr/bin/env python3
"""Adversarial two-stage contract tests for cycle-release-gate-v1."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "export_release_gate.py"
VALIDATOR = HERE.parents[1] / ".codex" / "skills" / "legendary-cycle" / "scripts" / "validate_legendary_cycle.py"
HOSTILE = HERE / "fixtures" / "release-gate" / "review-12-15-hostile.json"
SPEC = importlib.util.spec_from_file_location("release_gate_validator", VALIDATOR)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode()


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def receipt(format_name: str, **pins: object) -> dict[str, object]:
    value: dict[str, object] = {"format": format_name, **pins}
    value["receipt_digest"] = digest(value)
    return value


class ReleaseGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.activate = self.fixture("activate")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def fixture(self, stage: str) -> dict[str, object]:
        authority = {
            "kind": "barkpark_cycle_fleet",
            "workspace_id": "11111111-1111-4111-8111-111111111111",
            "workspace_slug": "default",
            "project_id": "22222222-2222-4222-8222-222222222222",
            "project_slug": "default",
            "canonical_origin": "https://guerrilla.barkpark.cloud",
            "epic_id": "task-quality-standard-chrono-root-2026-07-18",
            "wave_id": "task-quality-standard-chrono-wave-4-2026-07-19",
            "wave_revision": "33333333-3333-4333-8333-333333333333",
        }
        defects = {name: [] for name in MODULE.RELEASE_DEFECT_LISTS}
        ledger = {
            "profile": "legendary",
            "scope": {key: authority[key] for key in ("workspace_id", "project_id", "epic_id", "wave_id")},
            "wave_revision": authority["wave_revision"],
            "inventory_count": 503, "assigned_count": 503, "assigned_occurrences": 503,
            "shipped_count": 42, "stalled_count": 291, "excluded_count": 170,
            "inventory_digest": "a" * 64, "plan_digest": "b" * 64,
            "reconciliation_digest": "c" * 64, "correction_of_digest": "d" * 64,
            "correction_receipt_digest": "e" * 64, "fleet_complete": True, "exact": True,
            **defects,
        }
        fleet = {"build": {"planned": 28, "started": 28, "completed": 28, "failed": 0,
                            "missing": 0, "assignments": [{"id": "build-01", "status": "completed",
                                                           "evidence": "paper://build-01"}]}}
        lifecycle = {
            "format": "quarantine-promotion-v1",
            "current": {"wave_id": authority["wave_id"], "wave_revision": authority["wave_revision"]},
            "promotion": {"action": "promote", "event_id": "promotion-1"},
            "authority_evidence": {"admission_id": "admission-1"}, "quarantines": [],
            "superseded": [{"wave_id": "task-quality-standard-chrono-wave-3-2026-07-18",
                            "wave_revision": "44444444-4444-4444-8444-444444444444",
                            "semantic_snapshot": {"shipped_count": 53, "stalled_count": 280,
                                                  "excluded_count": 170},
                            "delta": {"shipped": -11, "stalled": 11, "excluded": 0}}],
            "historical_ancestry": [],
        }
        cycle = {"authority": authority, "cycle_ledger": ledger, "fleet": fleet,
                 "correction_lifecycle": lifecycle}
        block = {"type": "callout", "title": "Release authority",
                 "cycle_ledger": ledger, "fleet": fleet}
        campaign = {"_id": "task-quality-campaign-paper", "_rev": "66666666-6666-4666-8666-666666666666",
                    "body": {"version": 1, "blocks": [copy.deepcopy(block)]}}
        successor = {"_id": "task-quality-successor-paper", "_rev": "77777777-7777-4777-8777-777777777777",
                     "body": {"version": 1, "blocks": [copy.deepcopy(block)]}}
        authorities = {
            name: receipt(format_name, authority=name, epic_id=authority["epic_id"],
                          wave_revision=authority["wave_revision"])
            for name, format_name in MODULE.RELEASE_AUTHORITY_FORMATS.items()
        }
        proposed = {"epic_id": authority["epic_id"], "wave_id": authority["wave_id"],
                    "profile": "legendary", "inventory_digest": ledger["inventory_digest"],
                    "plan_digest": ledger["plan_digest"],
                    "correction_of_digest": ledger["correction_of_digest"]}
        evidence: dict[str, object] = {
            "gate_id": "88888888-8888-4888-8888-888888888888",
            "challenge_id": "99999999-9999-4999-8999-999999999999",
            "gate_digest": "f" * 64, "proposed_successor": proposed,
            "cycle": cycle, "cycle_cli": copy.deepcopy(cycle), "prior_authorities": authorities,
            "papers": {"campaign": campaign, "successor": successor}, "readers": {},
        }
        if stage == "open":
            proposed["wave_id"] = "task-quality-standard-chrono-wave-5-proposed"
            proposed["correction_of_digest"] = "9" * 64
            evidence.update({"gate_id": None, "challenge_id": None, "gate_digest": None,
                             "papers": {"campaign": campaign, "successor": None}, "readers": None})
            return evidence

        projection = {"cycle_ledger": ledger, "fleet": fleet, "correction_context": lifecycle}
        markers = (f"current {authority['wave_id']} {authority['wave_revision']} 503 total 42 shipped "
                   "291 stalled 170 excluded superseded task-quality-standard-chrono-wave-3-2026-07-18 "
                   "53 shipped 280 stalled 170 excluded -11 shipped +11 stalled meaningful release evidence")
        readers = {}
        for role, paper in (("campaign", campaign), ("successor", successor)):
            content_digest = digest(paper["body"]["blocks"])
            role_captures = {}
            for ordinal, surface in enumerate(MODULE.RELEASE_READER_SURFACES, 1):
                raw: object = markers if surface != "public_html" else f"<article>{markers}</article>"
                if surface == "source_json":
                    raw = {"id": paper["_id"], "_rev": paper["_rev"],
                           "source": {"kind": "blocks", "blocks": copy.deepcopy(paper["body"]["blocks"])}}
                route = "render" if surface == "public_html" else "source"
                address = (
                    "https://guerrilla.barkpark.cloud/w/default/p/default/v1/cycles/"
                    f"{authority['epic_id']}/{authority['wave_id']}/release-gates/"
                    f"{evidence['gate_id']}/papers/{role}/{route}"
                    f"?candidate_id={paper['_rev']}&wave_revision={authority['wave_revision']}"
                )
                role_captures[surface] = {
                    "producer": "barkpark-server-capture-v1", "gate_id": evidence["gate_id"],
                    "challenge_id": evidence["challenge_id"],
                    "capture_id": f"{6 if role == 'campaign' else 7}{ordinal:07x}-aaaa-4aaa-8aaa-{ordinal:012x}",
                    "address": address,
                    "document_id": paper["_id"], "revision": paper["_rev"],
                    "content_digest": content_digest, "gate_digest": evidence["gate_digest"],
                    "raw": raw, "normalized_projection": copy.deepcopy(projection),
                }
            readers[role] = role_captures
        evidence["readers"] = readers
        return evidence

    def build(self, stage: str = "activate", evidence: dict[str, object] | None = None) -> dict[str, object]:
        return MODULE.build_release_gate_bundle(stage, evidence or self.activate)

    def test_open_bundle_has_null_successor_and_readers_and_binds_proposed_contract(self) -> None:
        bundle = self.build("open", self.fixture("open"))
        self.assertEqual(bundle["format"], "cycle-release-evidence-bundle-v1")
        self.assertEqual(bundle["purpose"], "non-authoritative-preflight")
        self.assertIsNone(bundle["evidence"]["papers"]["successor"])
        self.assertIsNone(bundle["evidence"]["readers"])
        self.assertIsNone(bundle["receipt"]["readers_digest"])
        self.assertEqual(bundle["receipt"]["format"], "cycle-release-gate-v1")

    def test_activate_retains_raw_server_capture_bundle_and_exact_receipt(self) -> None:
        bundle = self.build()
        self.assertEqual(bundle["evidence"], self.activate)
        receipt_value = bundle["receipt"]
        unsigned = {key: value for key, value in receipt_value.items() if key != "receipt_digest"}
        self.assertEqual(receipt_value["receipt_digest"], digest(unsigned))
        self.assertEqual(receipt_value["cycle"]["shipped_count"], 42)
        self.assertEqual(receipt_value["cycle"]["stalled_count"], 291)
        self.assertEqual(set(receipt_value["authorities"]), set(MODULE.RELEASE_AUTHORITY_FORMATS))
        self.assertEqual(receipt_value["readers_digest"], digest(self.activate["readers"]))

    def test_hostile_inventory_covers_reviews_12_through_15(self) -> None:
        manifest = json.loads(HOSTILE.read_text())
        ids = {row["id"] for row in manifest["fixtures"]}
        self.assertEqual(len(ids), 14)
        self.assertTrue(all(any(value.startswith(f"r{review}-") for value in ids) for review in range(12, 16)))

    def test_review_12_15_hostile_inputs_fail_closed(self) -> None:
        def foreign_b1(e):
            value = e["prior_authorities"]["b1_scope"]
            value["epic_id"] = "foreign"
            value["receipt_digest"] = digest({k: v for k, v in value.items() if k != "receipt_digest"})

        cases = {
            "r12-wrong-b1-scope": foreign_b1,
            "r12-semantic-receipt-drift": lambda e: e["prior_authorities"]["semantic_receipt"].__setitem__("receipt_digest", "0" * 64),
            "r12-wrong-terminal-tuple": lambda e: e["cycle"]["cycle_ledger"].__setitem__("shipped_count", 43),
            "r12-paper-ledger-drift": lambda e: e["papers"]["campaign"]["body"]["blocks"][0]["cycle_ledger"].__setitem__("stalled_count", 290),
            "r12-source-drift": lambda e: e["readers"]["campaign"]["source_json"]["raw"]["source"].__setitem__("blocks", []),
            "r13-inventory-not-503": lambda e: e["cycle"]["cycle_ledger"].__setitem__("inventory_count", 502),
            "r13-duplicate-unit": lambda e: e["cycle"]["cycle_ledger"].__setitem__("duplicate_assignment_unit_ids", ["task-1"]),
            "r14-missing-prior-authority": lambda e: e["prior_authorities"].pop("ordering"),
            "r14-stale-paper-revision": lambda e: e["readers"]["successor"]["source_json"].__setitem__("revision", "latest"),
            "r14-nonmeaningful-reader": lambda e: e["readers"]["successor"]["tui"].__setitem__("raw", "..."),
            "r15-missing-superseded-wave3": lambda e: e["cycle"]["correction_lifecycle"].__setitem__("superseded", []),
            "r15-reader-current-drift": lambda e: e["readers"]["campaign"]["task_board"].__setitem__("raw", "meaningful but stale reader without authority markers"),
        }
        manifest = json.loads(HOSTILE.read_text())
        self.assertEqual(set(cases), {row["id"] for row in manifest["fixtures"] if row["expected"] == "reject"})
        for name, mutate in cases.items():
            with self.subTest(name=name):
                evidence = copy.deepcopy(self.activate)
                mutate(evidence)
                if name.startswith("r12-wrong-terminal") or name.startswith("r13-") or name.startswith("r15-missing"):
                    evidence["cycle_cli"] = copy.deepcopy(evidence["cycle"])
                with self.assertRaises(MODULE.ReleaseGateError):
                    self.build(evidence=evidence)

    def test_mutable_or_wrong_challenge_capture_is_rejected(self) -> None:
        for mutation in ("address", "producer", "challenge_id", "capture_id"):
            with self.subTest(mutation=mutation):
                evidence = copy.deepcopy(self.activate)
                capture = evidence["readers"]["campaign"]["cli"]
                if mutation == "address":
                    capture[mutation] = "https://guerrilla.barkpark.cloud/papers/mutable-slug"
                elif mutation == "producer":
                    capture[mutation] = "caller-upload-v1"
                else:
                    capture[mutation] = ""
                with self.assertRaises(MODULE.ReleaseGateError):
                    self.build(evidence=evidence)

    def test_reused_server_capture_id_is_rejected(self) -> None:
        evidence = copy.deepcopy(self.activate)
        evidence["readers"]["successor"]["tui"]["capture_id"] = (
            evidence["readers"]["campaign"]["cli"]["capture_id"]
        )
        with self.assertRaises(MODULE.ReleaseGateError):
            self.build(evidence=evidence)

    def test_synthetic_or_incompletely_pinned_reader_addresses_are_rejected(self) -> None:
        evidence = copy.deepcopy(self.activate)
        capture = evidence["readers"]["campaign"]["source_json"]
        capture["address"] = (
            f"capture://source/{capture['document_id']}/revisions/{capture['revision']}"
            f"?release_gate={capture['gate_digest']}"
        )
        with self.assertRaises(MODULE.ReleaseGateError):
            self.build(evidence=evidence)

        evidence = copy.deepcopy(self.activate)
        capture = evidence["readers"]["campaign"]["source_json"]
        capture["address"] = capture["address"].replace(
            "https://guerrilla.barkpark.cloud/w/default/p/default",
            "https://evil.example/anything/w/default/p/default",
        )
        with self.assertRaises(MODULE.ReleaseGateError):
            self.build(evidence=evidence)

        evidence = copy.deepcopy(self.activate)
        capture = evidence["readers"]["campaign"]["source_json"]
        capture["address"] = capture["address"].replace(
            f"candidate_id={capture['revision']}&", ""
        )
        with self.assertRaises(MODULE.ReleaseGateError):
            self.build(evidence=evidence)

    def test_cli_rerun_is_identical_and_invalid_input_never_replaces_output(self) -> None:
        evidence_path = self.root / "evidence.json"
        evidence_path.write_bytes(canonical(self.activate))
        outputs = (self.root / "first.json", self.root / "second.json")
        for output in outputs:
            completed = subprocess.run([sys.executable, str(SCRIPT), "--stage", "activate",
                                        "--evidence-json", str(evidence_path), "--output", str(output)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        self.assertEqual(outputs[0].read_bytes(), outputs[1].read_bytes())

        bad = copy.deepcopy(self.activate)
        bad["readers"]["successor"]["tui"]["raw"] = ""
        evidence_path.write_bytes(canonical(bad))
        protected = self.root / "protected.json"
        protected.write_bytes(b"sentinel")
        completed = subprocess.run([sys.executable, str(SCRIPT), "--stage", "activate",
                                    "--evidence-json", str(evidence_path), "--output", str(protected)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(protected.read_bytes(), b"sentinel")
        self.assertEqual(list(self.root.glob(".protected.json.*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
