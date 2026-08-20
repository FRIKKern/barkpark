#!/usr/bin/env python3

import argparse
import copy
import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "validate_epic_cycle.py"
SPEC = importlib.util.spec_from_file_location("validate_epic_cycle", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class EpicCyclePreflightTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.task = {
            "doc": {
                "doc_id": "slice-1",
                "status": "published",
                "content": {
                    "lifecycle_status": "in_progress",
                    "parent_id": "epic-1",
                    "labels": ["proj:epic-1", "phase:build", "files:skill"],
                    "acceptance_criteria": [{"criterion": "gate passes", "met": False}],
                    "wave_paper": "paper-1",
                    "claim": {
                        "worker": "codex-lead",
                        "epoch": 3,
                        "ts_iso": datetime.now(timezone.utc).isoformat(),
                    },
                    "code_refs": {"branch": "feat/slice-1", "worktree": "/tmp/slice-1", "commits": []},
                    "last_worked_at": "2026-07-14T12:00:00Z",
                },
            }
        }
        fleet = {}
        for phase, (agent_type, planned) in MODULE.FLEET_SPECS.items():
            assignments = [
                {
                    "id": f"{phase}-{index + 1}",
                    "agent_type": agent_type,
                    "status": "completed",
                    "evidence": f"paper://{phase}/{index + 1}",
                }
                for index in range(planned)
            ]
            fleet[phase] = {
                "agent_type": agent_type,
                "effort": MODULE.FLEET_EFFORTS[phase],
                "planned": planned,
                "started": planned,
                "completed": planned,
                "failed": 0,
                "missing": 0,
                "assignments": assignments,
            }
        ledger = {
            "profile": "epic",
            "scope": {"workspace_id": "workspace-1", "epic_id": "epic-1", "wave_id": "wave-1"},
            "wave_revision": "wave-rev-1",
            "exact": True,
        }
        self.paper = {
            "_id": "paper-1",
            "_draft": False,
            "_createdAt": "2026-07-15T00:05:00Z",
            "body": {
                "version": 1,
                "blocks": [
                    {"type": "heading", "text": "User wish"},
                    {"type": "quote", "text": "make Codex task obsessed"},
                    {"type": "heading", "text": "Strategic direction"},
                    {"type": "heading", "text": "Agent fleet"},
                    {"type": "callout", "title": "COMPLETE", "fleet": fleet},
                    {
                        "type": "callout",
                        "title": "CycleFleet ledger",
                        "cycle_ledger": ledger,
                    },
                    {"type": "heading", "text": "Survey digest and coverage gaps"},
                    {"type": "heading", "text": "Verification plan"},
                    {"type": "heading", "text": "Decisions and rationale"},
                    {"type": "heading", "text": "Wave slice"},
                ],
            },
        }

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, value):
        path = self.root / name
        if isinstance(value, str):
            path.write_text(value, encoding="utf-8")
        else:
            path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def fleet(self, paper):
        paper = MODULE.paper_doc(paper)
        return MODULE.paper_fleet(paper)

    def resign_ledger(self, ledger):
        ledger["attempts"].sort(key=lambda attempt: (attempt["ordinal"], attempt["attempt_id"]))
        for attempt in ledger["attempts"]:
            semantic = {key: value for key, value in attempt.items() if key != "attempt_digest"}
            attempt["attempt_digest"] = MODULE.canonical_digest(semantic)
        ledger["manifest_digest"] = MODULE.canonical_digest(ledger["manifest"])
        ledger["attempts_digest"] = MODULE.canonical_digest(ledger["attempts"])
        ledger["summary"] = MODULE.benchmark_summary(ledger["attempts"])
        ledger["summary_digest"] = MODULE.canonical_digest(ledger["summary"])
        base = {key: value for key, value in ledger.items() if key != "ledger_digest"}
        ledger["ledger_digest"] = MODULE.canonical_digest(base)
        return ledger

    def ledger(self, task=None, paper=None, cycle_phase="epic"):
        task = task or self.task
        paper = MODULE.paper_doc(paper or self.paper)
        fields = MODULE.task_fields(MODULE.task_doc(task))
        fleet = self.fleet(paper)
        attempts = []
        ordinal = 0
        for phase, record in fleet.items():
            for assignment in record["assignments"]:
                ordinal += 1
                effort = "high" if phase in {"build", "review"} else "medium"
                attempts.append(
                    {
                        "attempt_id": f"attempt-{phase}-{assignment['id']}",
                        "replaces_attempt_id": None,
                        "ordinal": ordinal,
                        "treatment": "fleet-reconciliation",
                        "status": "completed",
                        "costs": {
                            "wall_seconds": {"state": "observed", "value": ordinal},
                            "token_count": {"state": "unsupported", "reason": "fixture provider"},
                            "context_bytes": {"state": "missing", "reason": "fixture absent"},
                            "cpu_percent": {"state": "invalid", "reason": "fixture reset"},
                        },
                        "provenance": {"source": "validator fixture"},
                        "payload": {
                            "fleet_assignment": {
                                "phase": phase,
                                "assignment_id": assignment["id"],
                                "agent_type": assignment["agent_type"],
                                "evidence": assignment["evidence"],
                                "model_reasoning_effort": effort,
                            }
                        },
                    }
                )
        ledger = {
            "format": MODULE.LEDGER_FORMAT,
            "experiment": {
                "workspace_id": "workspace-fixture",
                "epic_id": fields.get("parent_id"),
                "wave_id": paper["_id"],
                "experiment_id": f"{cycle_phase}-fleet-fixture",
                "phase": cycle_phase,
                "protocol_version": 1,
            },
            "manifest": {
                "fleet_contract": {
                    "version": 1,
                    "paper_fleet_digest": MODULE.canonical_digest(fleet),
                }
            },
            "manifest_digest": "",
            "attempts": attempts,
            "attempts_digest": "",
            "summary": {},
            "summary_digest": "",
            "ledger_digest": "",
        }
        return self.resign_ledger(ledger)

    def args(
        self,
        task=None,
        paper=None,
        pr_body="Summary\n\nTask: slice-1\n",
        phase="build",
        require_debrief=False,
        include_wish=True,
        ledger=None,
        include_ledger=True,
        allow_legacy=False,
    ):
        task = task or self.task
        paper = paper or self.paper
        blocks = MODULE.paper_blocks(paper.get("result", paper))
        cycle_ledger = next(
            (block["cycle_ledger"] for block in blocks if "cycle_ledger" in block),
            None,
        )
        fleet = next((block["fleet"] for block in blocks if "fleet" in block), None)
        benchmark_ledger = ledger or self.ledger(task, paper)
        return argparse.Namespace(
            task=None,
            task_json=self.write("task.json", task),
            paper=None,
            paper_json=self.write("paper.json", paper),
            worker="codex-lead",
            phase=phase,
            require_debrief=require_debrief,
            fleet_ledger_json=(
                self.write("fleet-ledger.json", MODULE.canonical_json(benchmark_ledger))
                if include_ledger
                else None
            ),
            wish_file=self.write("wish.txt", "make Codex task obsessed") if include_wish else None,
            pr_body=self.write("pr.md", pr_body),
            cycle_json=(
                self.write("cycle.json", {"cycle_ledger": cycle_ledger, "fleet": fleet})
                if cycle_ledger is not None
                else None
            ),
            allow_pre_cyclefleet_paper_without_ledger=allow_legacy,
            workspace="default",
            project="default",
        )

    def test_valid_fixture_passes(self):
        self.assertEqual([], MODULE.validate(self.args()))

    def test_build_preflight_accepts_current_prior_fleet_without_future_completions(self):
        paper = copy.deepcopy(self.paper)
        fleet = self.fleet(paper)
        for phase in ("build", "review"):
            fleet[phase].update(
                {
                    "started": 0,
                    "completed": 0,
                    "failed": 0,
                    "missing": fleet[phase]["planned"],
                    "assignments": [],
                }
            )
        self.assertEqual([], MODULE.validate(self.args(paper=paper)))

    def test_build_and_review_require_canonical_ledger_export(self):
        errors = MODULE.validate(self.args(include_ledger=False))
        self.assertIn("build/review preflight requires --fleet-ledger-json", errors)

        args = self.args()
        args.fleet_ledger_json.write_text(
            args.fleet_ledger_json.read_text(encoding="utf-8") + "\n",
            encoding="utf-8",
        )
        self.assertTrue(
            any("bytes are not the canonical B1 exporter encoding" in error for error in MODULE.validate(args))
        )

    def test_python_digest_matches_b1_cross_runtime_golden_vector(self):
        self.assertEqual(
            '{"a":"nord","b":[{"a":true,"z":1}]}',
            MODULE.canonical_json({"b": [{"z": 1, "a": True}], "a": "nord"}),
        )
        self.assertEqual(
            "289df3f385174ac1840b87f3de4738a42efacf6be94f59af683f7d300a1f2a83",
            MODULE.canonical_digest({"b": [{"z": 1, "a": True}], "a": "nord"}),
        )

    def test_python_reproduces_b1_exporter_component_and_ledger_golden_digests(self):
        manifest = {
            "seed": 20260715,
            "widths": [1, 2, 3, 6],
            "operator": {"name": "benchmark", "api_key": "[REDACTED]"},
        }

        def attempt(attempt_id, ordinal):
            semantic = {
                "attempt_id": attempt_id,
                "replaces_attempt_id": None,
                "ordinal": ordinal,
                "treatment": "width-1",
                "status": "completed",
                "costs": {
                    "wall_seconds": {"state": "observed", "value": 3.25, "unit": "seconds"},
                    "token_count": {"state": "unsupported", "reason": "provider omitted usage"},
                    "context_bytes": {"state": "missing", "reason": "sample absent"},
                    "cpu_percent": {"state": "invalid", "reason": "counter reset"},
                },
                "provenance": {"sampler": "stdlib", "host": "fixture"},
                "payload": {"complete": True, "verified_yield": 6},
            }
            return {**semantic, "attempt_digest": MODULE.canonical_digest(semantic)}

        attempts = [attempt("attempt-a", 1), attempt("attempt-b", 2)]
        summary = MODULE.benchmark_summary(attempts)
        base = {
            "format": MODULE.LEDGER_FORMAT,
            "experiment": {
                "workspace_id": "00000000-0000-0000-0000-000000000002",
                "epic_id": "epic-golden",
                "wave_id": "wave-golden",
                "experiment_id": "experiment-golden",
                "phase": "legendary",
                "protocol_version": 1,
            },
            "manifest": manifest,
            "manifest_digest": MODULE.canonical_digest(manifest),
            "attempts": attempts,
            "attempts_digest": MODULE.canonical_digest(attempts),
            "summary": summary,
            "summary_digest": MODULE.canonical_digest(summary),
        }
        self.assertEqual(
            "615f47d9bde44b357f54b888dd7a0e9bba5d7a0f6b1baa68c18662839b959f6e",
            base["manifest_digest"],
        )
        self.assertEqual(
            "1815ca312f91132a18732fb585c7339025f0a2bc5920fc02c1459be04a9c3100",
            base["attempts_digest"],
        )
        self.assertEqual(
            "5bd7d2914bc4ae184608cb1c6994de16c8c9502ac76ea3803521781f787bc5ec",
            base["summary_digest"],
        )
        self.assertEqual(
            "0db779ba31f0f71a1faf92610fcdda3633b9b22ac98621aa694164c5b1b16dce",
            MODULE.canonical_digest(base),
        )

    def test_exporter_to_validator_rejects_paper_only_inflation(self):
        ledger = self.ledger()
        ledger["attempts"] = [
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["assignment_id"] != "build-3"
        ]
        for ordinal, attempt in enumerate(ledger["attempts"], start=1):
            attempt["ordinal"] = ordinal
        self.resign_ledger(ledger)
        self.assertIn(
            "fleet ledger build terminal completions do not match the Paper projection",
            MODULE.validate(self.args(ledger=ledger)),
        )

    def test_exporter_to_validator_rejects_stale_paper_projection(self):
        ledger = self.ledger()
        paper = copy.deepcopy(self.paper)
        self.fleet(paper)["build"]["assignments"][0]["evidence"] = "paper://build/new-evidence"
        errors = MODULE.validate(self.args(paper=paper, ledger=ledger))
        self.assertIn("fleet ledger Paper fleet digest is stale", errors)
        self.assertIn(
            "fleet ledger build terminal completions do not match the Paper projection",
            errors,
        )

    def test_exporter_to_validator_retry_counts_terminal_leaf_and_all_attempt_costs(self):
        paper = copy.deepcopy(self.paper)
        self.fleet(paper)["verify"]["failed"] = 1
        ledger = self.ledger(paper=paper)
        original = next(
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["assignment_id"] == "verify-1"
        )
        original["status"] = "failed"
        replacement = copy.deepcopy(original)
        replacement["attempt_id"] = "attempt-verify-1-retry"
        replacement["replaces_attempt_id"] = original["attempt_id"]
        replacement["ordinal"] = max(attempt["ordinal"] for attempt in ledger["attempts"]) + 1
        replacement["status"] = "completed"
        ledger["attempts"].append(replacement)
        self.resign_ledger(ledger)

        self.assertEqual([], MODULE.validate(self.args(paper=paper, ledger=ledger)))
        self.assertEqual(len(ledger["attempts"]), ledger["summary"]["attempt_count"])
        self.assertEqual(set(MODULE.COST_STATES), set(ledger["summary"]["cost_states"]))

    def test_exporter_to_validator_rejects_duplicate_and_non_contiguous_ordinals(self):
        duplicate = self.ledger()
        duplicate["attempts"][-1]["ordinal"] = duplicate["attempts"][-2]["ordinal"]
        self.resign_ledger(duplicate)
        self.assertIn(
            "fleet ledger attempt ordinals are not unique",
            MODULE.validate(self.args(ledger=duplicate)),
        )

        non_contiguous = self.ledger()
        non_contiguous["attempts"][-1]["ordinal"] += 1
        self.resign_ledger(non_contiguous)
        self.assertIn(
            "fleet ledger attempt ordinals are not contiguous from 1",
            MODULE.validate(self.args(ledger=non_contiguous)),
        )

    def test_exporter_to_validator_rejects_independent_attempts_for_one_assignment(self):
        paper = copy.deepcopy(self.paper)
        self.fleet(paper)["verify"]["failed"] = 1
        ledger = self.ledger(paper=paper)
        original = next(
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["assignment_id"] == "verify-1"
        )
        independent = copy.deepcopy(original)
        independent["attempt_id"] = "attempt-verify-1-independent"
        independent["ordinal"] = len(ledger["attempts"]) + 1
        independent["status"] = "failed"
        ledger["attempts"].append(independent)
        self.resign_ledger(ledger)

        self.assertIn(
            "fleet ledger logical assignment 'verify/verify-1' attempts do not form one "
            "linear replacement chain with exactly one terminal leaf",
            MODULE.validate(self.args(paper=paper, ledger=ledger)),
        )

    def test_exporter_to_validator_rejects_dangling_replacement(self):
        ledger = self.ledger()
        ledger["attempts"][-1]["replaces_attempt_id"] = "attempt-missing"
        self.resign_ledger(ledger)
        self.assertTrue(
            any("replacement ancestry is invalid" in error for error in MODULE.validate(self.args(ledger=ledger)))
        )

    def test_exporter_to_validator_rejects_coerced_unknown_cost(self):
        ledger = self.ledger()
        attempt = ledger["attempts"][0]
        attempt["costs"]["token_count"] = {"state": "unknown", "value": 0}
        semantic = {key: value for key, value in attempt.items() if key != "attempt_digest"}
        attempt["attempt_digest"] = MODULE.canonical_digest(semantic)
        ledger["attempts_digest"] = MODULE.canonical_digest(ledger["attempts"])
        base = {key: value for key, value in ledger.items() if key != "ledger_digest"}
        ledger["ledger_digest"] = MODULE.canonical_digest(base)
        self.assertTrue(
            any("costs do not use exhaustive typed states" in error for error in MODULE.validate(self.args(ledger=ledger)))
        )

    def test_exporter_to_validator_rejects_wrong_agent_type_and_non_high_build_or_review(self):
        ledger = self.ledger()
        build = next(
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["phase"] == "build"
        )
        build["payload"]["fleet_assignment"]["agent_type"] = "executor"
        build["payload"]["fleet_assignment"]["model_reasoning_effort"] = "medium"
        review = next(
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["phase"] == "review"
        )
        review["payload"]["fleet_assignment"]["model_reasoning_effort"] = "medium"
        self.resign_ledger(ledger)
        errors = MODULE.validate(self.args(ledger=ledger))
        self.assertTrue(any("fleet_assignment agent_type is invalid" in error for error in errors))
        self.assertTrue(any("Build effort is not exactly high" in error for error in errors))
        self.assertTrue(any("Review effort is not exactly high" in error for error in errors))

    def test_exporter_to_validator_rejects_wrong_epic_scope(self):
        ledger = self.ledger()
        ledger["experiment"]["epic_id"] = "another-epic"
        self.resign_ledger(ledger)
        self.assertTrue(any("fleet ledger epic scope" in error for error in MODULE.validate(self.args(ledger=ledger))))

    def test_unrelated_paper_content_does_not_stale_fleet_projection(self):
        ledger = self.ledger()
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"].append({"type": "paragraph", "text": "Unrelated reader context"})
        self.assertEqual([], MODULE.validate(self.args(paper=paper, ledger=ledger)))
    def test_canonical_epic_projection_matches_live_cyclefleet(self):
        paper = copy.deepcopy(self.paper)
        fleet = next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)
        ledger = next(
            block["cycle_ledger"] for block in paper["body"]["blocks"] if "cycle_ledger" in block
        )
        args = self.args(paper=paper)
        args.cycle_json = self.write("cycle.json", {"cycle_ledger": ledger, "fleet": fleet})
        self.assertEqual([], MODULE.validate(args))

    def test_live_cyclefleet_lookup_passes_explicit_workspace_and_project(self):
        args = self.args()
        args.cycle_json = None
        blocks = MODULE.paper_blocks(self.paper)
        ledger = next(block["cycle_ledger"] for block in blocks if "cycle_ledger" in block)
        fleet = next(block["fleet"] for block in blocks if "fleet" in block)

        with mock.patch.object(
            MODULE, "command_json", return_value={"cycle_ledger": ledger, "fleet": fleet}
        ) as command:
            self.assertEqual([], MODULE.validate_canonical_cycle_projection(self.paper, args))

        command.assert_called_once_with(
            "bp", "--workspace", "default", "--project", "default",
            "cycle", "show", "epic-1", "wave-1", "-o", "json"
        )

    def test_canonical_epic_ledger_and_fleet_drift_fail(self):
        paper = copy.deepcopy(self.paper)
        fleet = next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)
        ledger = next(
            block["cycle_ledger"] for block in paper["body"]["blocks"] if "cycle_ledger" in block
        )
        live_ledger = copy.deepcopy(ledger)
        live_ledger["exact"] = False
        live_fleet = copy.deepcopy(fleet)
        live_fleet["review"]["completed"] = 2
        args = self.args(paper=paper)
        args.cycle_json = self.write(
            "cycle-drift.json", {"cycle_ledger": live_ledger, "fleet": live_fleet}
        )
        errors = MODULE.validate(args)
        self.assertIn(
            "Epic Paper cycle_ledger does not exactly match the live CycleFleet authority",
            errors,
        )
        self.assertIn("Epic Paper fleet does not exactly match the live CycleFleet authority", errors)

    def test_missing_cycle_ledger_requires_explicit_pre_cyclefleet_opt_in(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"] = [
            block for block in paper["body"]["blocks"] if "cycle_ledger" not in block
        ]
        errors = MODULE.validate(self.args(paper=paper))
        self.assertTrue(any("--allow-pre-cyclefleet-paper-without-ledger" in error for error in errors))

    def test_live_pre_cyclefleet_paper_can_opt_in_to_legacy_compatibility(self):
        paper = copy.deepcopy(self.paper)
        paper["_createdAt"] = "2026-07-14T23:59:59Z"
        paper["body"]["blocks"] = [
            block for block in paper["body"]["blocks"] if "cycle_ledger" not in block
        ]
        args = self.args(paper=paper, allow_legacy=True)
        args.paper_json = None
        args.paper = "paper-1"
        with mock.patch.object(MODULE, "command_json", return_value=paper) as command:
            self.assertEqual([], MODULE.validate(args))
        command.assert_called_once_with("bp", "doc", "get", "paper", "paper-1", "-o", "json")

    def test_offline_json_cannot_spoof_pre_cyclefleet_created_at(self):
        paper = copy.deepcopy(self.paper)
        paper["_createdAt"] = "2020-01-01T00:00:00Z"
        paper["body"]["blocks"] = [
            block for block in paper["body"]["blocks"] if "cycle_ledger" not in block
        ]
        errors = MODULE.validate(self.args(paper=paper, allow_legacy=True))
        self.assertIn(
            "legacy ledger omission requires live --paper retrieval; --paper-json "
            "cannot prove immutable _createdAt metadata",
            errors,
        )

    def test_post_cutoff_ledgerless_paper_is_not_made_legacy_by_flag(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"] = [
            block for block in paper["body"]["blocks"] if "cycle_ledger" not in block
        ]
        args = self.args(paper=paper, allow_legacy=True)
        args.paper_json = None
        args.paper = "paper-1"
        with mock.patch.object(MODULE, "command_json", return_value=paper):
            errors = MODULE.validate(args)
        self.assertTrue(any("not proven pre-CycleFleet" in error for error in errors))

    def test_legacy_flag_requires_machine_readable_created_at(self):
        paper = copy.deepcopy(self.paper)
        paper.pop("_createdAt")
        paper["body"]["blocks"] = [
            block for block in paper["body"]["blocks"] if "cycle_ledger" not in block
        ]
        args = self.args(paper=paper, allow_legacy=True)
        args.paper_json = None
        args.paper = "paper-1"
        with mock.patch.object(MODULE, "command_json", return_value=paper):
            errors = MODULE.validate(args)
        self.assertTrue(any("_createdAt" in error for error in errors))

    def test_missing_claim_fails(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"]["claim"] = None
        self.assertIn("task has no active claim", MODULE.validate(self.args(task=task)))

    def test_stale_claim_lease_fails(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"]["claim"]["ts_iso"] = (
            datetime.now(timezone.utc) - timedelta(seconds=MODULE.CLAIM_TTL_SECONDS + 1)
        ).isoformat()
        self.assertIn(
            "task claim lease is not live; pulse and reread before preflight",
            MODULE.validate(self.args(task=task)),
        )

    def test_expected_worker_is_mandatory(self):
        args = self.args()
        args.worker = None
        self.assertIn("preflight requires an expected worker", MODULE.validate(args))

    def test_wrong_paper_link_fails(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"]["wave_paper"] = "paper-wrong"
        self.assertTrue(any("task wave_paper" in error for error in MODULE.validate(self.args(task=task))))

    def test_blank_criterion_text_fails(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"]["acceptance_criteria"] = [{"criterion": "   "}]
        self.assertIn("task has no acceptance criteria", MODULE.validate(self.args(task=task)))

    def test_incomplete_paper_fails(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"] = paper["body"]["blocks"][:-1]
        self.assertIn("paper is missing required build heading: wave slice", MODULE.validate(self.args(paper=paper)))

    def test_build_preflight_requires_prior_typed_fleet(self):
        paper = copy.deepcopy(self.paper)
        fleet = next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)
        fleet["survey"].update({"completed": 0, "missing": 12, "assignments": []})
        errors = MODULE.validate(self.args(paper=paper))
        self.assertIn("fleet survey requires 12 completed typed assignments before build", errors)

    def test_review_preflight_rejects_extra_build_assignment(self):
        paper = copy.deepcopy(self.paper)
        fleet = next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)
        fleet["build"]["assignments"].append(
            {
                "id": "build-4",
                "agent_type": "epic-builder",
                "status": "completed",
                "evidence": "paper://build/4",
            }
        )
        fleet["build"].update({"started": 4, "completed": 4, "missing": 0})
        self.assertIn(
            "fleet build exceeds its exact 3-assignment contract",
            MODULE.validate(self.args(paper=paper, phase="review")),
        )

    def test_top_level_paper_blocks_pass(self):
        paper = copy.deepcopy(self.paper)
        paper["blocks"] = paper.pop("body")["blocks"]
        self.assertEqual([], MODULE.validate(self.args(paper=paper)))

    def test_content_paper_blocks_pass(self):
        paper = copy.deepcopy(self.paper)
        paper["content"] = paper.pop("body")
        self.assertEqual([], MODULE.validate(self.args(paper=paper)))

    def test_empty_top_level_blocks_fall_back_to_body(self):
        paper = copy.deepcopy(self.paper)
        paper["blocks"] = []
        self.assertEqual([], MODULE.validate(self.args(paper=paper)))

    def test_raw_api_paper_envelope_passes(self):
        self.assertEqual([], MODULE.validate(self.args(paper={"result": copy.deepcopy(self.paper)})))

    def test_build_task_without_file_ownership_fails(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"]["labels"] = ["proj:epic-1", "phase:build"]
        self.assertIn("build task has no files: ownership label", MODULE.validate(self.args(task=task)))

    def test_build_task_without_worktree_provenance_fails(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"].pop("code_refs")
        task["doc"]["content"].pop("last_worked_at")
        errors = MODULE.validate(self.args(task=task))
        self.assertIn("task has no code_refs.branch", errors)
        self.assertIn("build task has no code_refs.worktree", errors)
        self.assertIn("task has no last_worked_at code activity timestamp", errors)

    def test_malformed_code_refs_reports_failure(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"]["code_refs"] = ["legacy/path.py"]
        errors = MODULE.validate(self.args(task=task))
        self.assertIn("task code_refs is not an object", errors)
        self.assertIn("task has no code_refs.branch", errors)

    def test_malformed_provenance_values_fail(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"]["code_refs"] = {
            "branch": "feat/slice-1",
            "worktree": {"fake": True},
            "commits": "not-a-list",
        }
        task["doc"]["content"]["last_worked_at"] = "not-a-time"
        errors = MODULE.validate(self.args(task=task))
        self.assertIn("build task has no code_refs.worktree", errors)
        self.assertIn("task code_refs.commits is not a list of commit strings", errors)
        self.assertIn("task has no last_worked_at code activity timestamp", errors)

    def test_empty_required_label_values_fail(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"]["labels"] = ["proj:", "phase:   ", "files:"]
        errors = MODULE.validate(self.args(task=task))
        self.assertIn("task has no proj: label", errors)
        self.assertIn("task has no phase: label", errors)
        self.assertIn("build task has no files: ownership label", errors)

    def test_root_epic_passes_strategize_without_parent(self):
        task = copy.deepcopy(self.task)
        task["doc"]["content"].pop("parent_id")
        task["doc"]["content"].pop("acceptance_criteria")
        task["doc"]["content"]["labels"] = ["proj:epic-1", "phase:strategy"]
        paper = copy.deepcopy(self.paper)
        fleet_block = next(block for block in paper["body"]["blocks"] if "fleet" in block)
        paper["body"]["blocks"] = [
            {"type": "heading", "text": "User wish"},
            {"type": "quote", "text": "make Codex task obsessed"},
            {"type": "heading", "text": "Strategic direction"},
            {"type": "heading", "text": "Agent fleet"},
            fleet_block,
            next(block for block in self.paper["body"]["blocks"] if "cycle_ledger" in block),
            {"type": "heading", "text": "Survey"},
        ]
        self.assertEqual([], MODULE.validate(self.args(task=task, paper=paper, phase="strategize")))

    def test_strategize_requires_verbatim_wish_input(self):
        errors = MODULE.validate(self.args(phase="strategize", include_wish=False))
        self.assertIn("strategize preflight requires --wish-file", errors)

    def test_wish_in_metadata_only_fails(self):
        paper = copy.deepcopy(self.paper)
        paper["title"] = "make Codex task obsessed"
        paper["body"]["blocks"][1]["text"] = "different narrative"
        self.assertIn(
            "paper does not preserve the supplied wish verbatim",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_wish_in_non_narrative_block_metadata_fails(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"][1] = {
            "type": "image",
            "id": "make Codex task obsessed",
            "alt": "make Codex task obsessed",
        }
        self.assertIn(
            "paper does not preserve the supplied wish verbatim",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_wish_capture_removes_only_one_file_terminator(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"][1]["text"] = "make Codex task obsessed\n"
        args = self.args(paper=paper)
        args.wish_file = self.write("wish-with-user-newline.txt", "make Codex task obsessed\n\n")
        self.assertEqual([], MODULE.validate(args))

        paper["body"]["blocks"][1]["text"] = "make Codex task obsessed"
        args = self.args(paper=paper, phase="strategize")
        args.wish_file = self.write("wish-with-user-newline.txt", "make Codex task obsessed\n\n")
        self.assertIn("paper does not preserve the supplied wish verbatim", MODULE.validate(args))

    def test_review_preflight_does_not_require_future_debrief(self):
        self.assertEqual([], MODULE.validate(self.args(phase="review")))

    def test_post_review_gate_requires_debrief(self):
        errors = MODULE.validate(self.args(phase="review", require_debrief=True))
        self.assertIn("paper is missing required post-review heading: debrief", errors)

        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"].append({"type": "heading", "text": "Debrief"})
        self.assertEqual([], MODULE.validate(self.args(paper=paper, phase="review", require_debrief=True)))

    def test_post_review_gate_rejects_second_review_wave(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"].append({"type": "heading", "text": "Debrief"})
        fleet = next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)
        repeated = [
            {
                "id": f"review-2-{index + 1}",
                "agent_type": "code-reviewer",
                "status": "completed",
                "evidence": f"paper://review/round-2/reviewer-{index + 1}",
            }
            for index in range(3)
        ]
        fleet["review"]["assignments"].extend(repeated)
        fleet["review"].update({"started": 6, "completed": 6, "missing": 0})
        self.assertIn(
            "fleet review exceeds its exact 3-assignment contract",
            MODULE.validate(self.args(paper=paper, phase="review", require_debrief=True)),
        )

    def test_wrong_phase_effort_fails(self):
        paper = copy.deepcopy(self.paper)
        fleet = next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)
        fleet["survey"]["effort"] = "high"
        self.assertIn("fleet survey effort is not medium", MODULE.validate(self.args(paper=paper)))

    def test_literal_escaped_newline_fails(self):
        errors = MODULE.validate(self.args(pr_body="Summary\\n\\nTask: slice-1"))
        self.assertIn("PR body contains a literal escaped newline before its Task trailer", errors)

    def test_wrong_task_trailer_fails(self):
        errors = MODULE.validate(self.args(pr_body="Summary\n\nTask: another-task\n"))
        self.assertTrue(any("Task: slice-1" in error for error in errors))

    def test_task_trailer_split_across_lines_fails(self):
        errors = MODULE.validate(self.args(pr_body="Summary\n\nTask:\nslice-1\n"))
        self.assertTrue(any("Task: slice-1" in error for error in errors))

    def test_fleet_contract_pins_counts_and_high_build(self):
        skill = (SCRIPT.parents[1] / "SKILL.md").read_text(encoding="utf-8")
        fleet = (SCRIPT.parents[1] / "references" / "fleet-contract.md").read_text(encoding="utf-8")
        builder = (SCRIPT.parents[3] / "agents" / "epic-builder.toml").read_text(encoding="utf-8")
        self.assertIn("24 completed typed child assignments", skill)
        self.assertIn("12 Survey", skill)
        self.assertIn("6 Verify", skill)
        self.assertIn("3 high-effort Build", skill)
        self.assertIn("3 Review", skill)
        self.assertIn("model_reasoning_effort = \"high\"", builder)
        self.assertIn("Fleet gate", fleet)
        self.assertIn('"fleet": {', fleet)
        self.assertIn("preserve its evidence", fleet)
        self.assertIn("--fleet-ledger-json", fleet)
        self.assertIn("Every attempt, including failed", fleet)
        self.assertIn("model_reasoning_effort: high", fleet)
        self.assertIn("new immutable CycleFleet wave", fleet)


if __name__ == "__main__":
    unittest.main()
