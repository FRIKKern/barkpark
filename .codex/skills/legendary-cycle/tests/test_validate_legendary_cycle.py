#!/usr/bin/env python3

import argparse
import copy
import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "validate_legendary_cycle.py"
SPEC = importlib.util.spec_from_file_location("validate_legendary_cycle", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class LegendaryCyclePreflightTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.task = {
            "doc": {
                "doc_id": "legendary-slice-1",
                "status": "published",
                "content": {
                    "lifecycle_status": "in_progress",
                    "parent_id": "legendary-1",
                    "labels": ["proj:legendary-1", "phase:build", "files:papers-1-20"],
                    "acceptance_criteria": [{"criterion": "batch gate passes", "met": False}],
                    "wave_paper": "wave-1",
                    "claim": {
                        "worker": "legendary-lead",
                        "epoch": 2,
                        "ts_iso": datetime.now(timezone.utc).isoformat(),
                    },
                    "code_refs": {
                        "branch": "legendary/papers-1-20",
                        "worktree": "/tmp/legendary-papers-1-20",
                        "commits": [],
                    },
                    "last_worked_at": "2026-07-15T12:00:00Z",
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
                "evidence_proofs": [],
                "terminal_counts": {
                    "completed": planned,
                    "failed": 0,
                    "cancelled": 0,
                    "missing": 0,
                    "invalid": 0,
                },
                "invalid_assignments": 0,
            }
        self.paper = {
            "_id": "wave-1",
            "_draft": False,
            "body": {
                "version": 1,
                "blocks": [
                    {"type": "heading", "text": "User wish"},
                    {"type": "quote", "text": "repair every unreadable Paper"},
                    {"type": "heading", "text": "Strategic direction"},
                    {"type": "heading", "text": "Scale profile"},
                    {
                        "type": "callout",
                        "title": "Scale profile",
                        "scale_profile": {
                            "unit_definition": "Paper",
                            "unit_count": 300,
                            "inventory_evidence": "bp doc list paper --all -o json",
                            "target_surfaces": ["Studio", "TUI", "email"],
                            "minimum_multiplier": 5,
                            "concurrency_width": 3,
                            "build_formula": "max(15, ceil(unit_count / proven_batch_capacity))",
                            "proven_batch_capacity": 20,
                            "planned_build_assignments": 15,
                            "excluded_inventory": [],
                            "quality_rubric": {
                                "reader_visibility": "all target readers pass",
                                "preservation": "authored content is preserved",
                            },
                            "failure_threshold": 0.05,
                        },
                    },
                    {
                        "type": "callout",
                        "title": "CycleFleet ledger",
                        "content": [
                            {
                                "type": "text",
                                "value": "Legendary CycleFleet wave wave-rev-1: 300 inventoried, 300 assigned, 300 shipped, 0 stalled, 0 excluded; exact reconciliation true.",
                            }
                        ],
                        "cycle_ledger": {
                            "profile": "legendary",
                            "scope": {
                                "workspace_id": "workspace-1",
                                "project_id": "project-1",
                                "epic_id": "legendary-1",
                                "wave_id": "wave-1",
                            },
                            "wave_revision": "wave-rev-1",
                            "inventory_digest": "a" * 64,
                            "plan_digest": "b" * 64,
                            "reconciliation_digest": "c" * 64,
                            "scale_contract": {
                                "unit_definition": "Paper",
                                "unit_count": 300,
                                "inventory_evidence": "bp doc list paper --all -o json",
                                "target_surfaces": ["Studio", "TUI", "email"],
                                "minimum_multiplier": 5,
                                "concurrency_width": 3,
                                "build_formula": "max(15, ceil(unit_count / proven_batch_capacity))",
                                "excluded_inventory": [],
                                "quality_rubric": {
                                    "reader_visibility": "all target readers pass",
                                    "preservation": "authored content is preserved",
                                },
                                "failure_threshold": 0.05,
                            },
                            "inventory_count": 300,
                            "assigned_count": 300,
                            "assigned_occurrences": 300,
                            "shipped_count": 300,
                            "stalled_count": 0,
                            "excluded_count": 0,
                            "planned_builders": 15,
                            "duplicate_assignment_unit_ids": [],
                            "unknown_assignment_unit_ids": [],
                            "unknown_outcome_unit_ids": [],
                            "outcome_overlap_unit_ids": [],
                            "outcome_ownership_violation_unit_ids": [],
                            "unassigned_unit_ids": [],
                            "unaccounted_unit_ids": [],
                            "fleet_complete": True,
                            "exact": True,
                            "capacity": {
                                "sealed": True,
                                "proven_batch_capacity": 20,
                                "failure_rate": 0.0,
                                "failure_threshold": 0.05,
                                "golden_fixtures": ["paper://fixtures/good", "paper://fixtures/bad"],
                                "quality_rubric": {
                                    "reader_visibility": "all target readers pass",
                                    "preservation": "authored content is preserved",
                                },
                            },
                            "experiment": {
                                "required?": True,
                                "complete?": True,
                                "missing_rounds": [],
                                "round_counts": {
                                    "baseline": 3,
                                    "diverge": 3,
                                    "attack": 3,
                                    "converge": 3,
                                    "pilot": 3,
                                }
                            },
                        },
                    },
                    {"type": "heading", "text": "Agent fleet"},
                    {"type": "callout", "title": "COMPLETE", "fleet": fleet},
                    {"type": "heading", "text": "Survey digest and coverage gaps"},
                    {"type": "heading", "text": "Verification plan"},
                    {"type": "heading", "text": "Experiment plan"},
                    {"type": "heading", "text": "Experiment verdict"},
                    {"type": "heading", "text": "Decisions and rationale"},
                    {"type": "heading", "text": "Shard manifest"},
                ],
            },
        }

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, value):
        path = self.root / name
        path.write_text(value if isinstance(value, str) else json.dumps(value), encoding="utf-8")
        return path

    def resign_ledger(self, ledger):
        ledger["attempts"].sort(key=lambda attempt: (attempt["ordinal"], attempt["attempt_id"]))
        for attempt in ledger["attempts"]:
            semantic = {key: value for key, value in attempt.items() if key != "attempt_digest"}
            attempt["attempt_digest"] = MODULE.EPIC.canonical_digest(semantic)
        ledger["manifest_digest"] = MODULE.EPIC.canonical_digest(ledger["manifest"])
        ledger["attempts_digest"] = MODULE.EPIC.canonical_digest(ledger["attempts"])
        ledger["summary"] = MODULE.EPIC.benchmark_summary(ledger["attempts"])
        ledger["summary_digest"] = MODULE.EPIC.canonical_digest(ledger["summary"])
        base = {key: value for key, value in ledger.items() if key != "ledger_digest"}
        ledger["ledger_digest"] = MODULE.EPIC.canonical_digest(base)
        return ledger

    def ledger(self, task=None, paper=None):
        paper = MODULE.EPIC.paper_doc(paper or self.paper)
        fleet = MODULE.EPIC.paper_fleet(paper)
        cycle_ledger = next(
            (
                block["cycle_ledger"]
                for block in MODULE.EPIC.paper_blocks(paper)
                if "cycle_ledger" in block
            ),
            next(
                block["cycle_ledger"]
                for block in MODULE.EPIC.paper_blocks(self.paper)
                if "cycle_ledger" in block
            ),
        )
        scope = cycle_ledger["scope"]
        fence = self.scope_fence(cycle_ledger, fleet)
        attempts = []
        ordinal = 0
        for phase, record in fleet.items():
            for assignment in record["assignments"]:
                ordinal += 1
                attempts.append(
                    {
                        "attempt_id": f"attempt-{phase}-{assignment['id']}",
                        "replaces_attempt_id": None,
                        "ordinal": ordinal,
                        "treatment": "legendary-fleet-reconciliation",
                        "status": "completed",
                        "costs": {
                            "wall_seconds": {"state": "observed", "value": ordinal},
                            "token_count": {"state": "unsupported", "reason": "fixture provider"},
                            "context_bytes": {"state": "missing", "reason": "fixture absent"},
                            "cpu_percent": {"state": "invalid", "reason": "fixture reset"},
                        },
                        "provenance": {
                            "source": "legendary validator fixture",
                            "scope_receipt_digest": fence["receipt_digest"],
                            "wave_revision": fence["wave_revision"],
                        },
                        "payload": {
                            "fleet_assignment": {
                                "phase": phase,
                                "assignment_id": assignment["id"],
                                "agent_type": assignment["agent_type"],
                                "evidence": assignment["evidence"],
                                "model_reasoning_effort": (
                                    "high" if phase in {"build", "review"} else "medium"
                                ),
                            }
                        },
                    }
                )
        ledger = {
            "format": MODULE.EPIC.LEDGER_FORMAT,
            "experiment": {
                "workspace_id": scope["workspace_id"],
                "epic_id": scope["epic_id"],
                "wave_id": paper["_id"],
                "experiment_id": "legendary-fleet-fixture",
                "phase": "legendary",
                "protocol_version": 1,
            },
            "manifest": {
                "fleet_contract": {
                    "version": 1,
                    "paper_fleet_digest": MODULE.EPIC.canonical_digest(fleet),
                },
                "cycle_scope_fence": fence,
            },
            "manifest_digest": "",
            "attempts": attempts,
            "attempts_digest": "",
            "summary": {},
            "summary_digest": "",
            "ledger_digest": "",
        }
        return self.resign_ledger(ledger)

    def authority(self, cycle_ledger):
        scope = cycle_ledger["scope"]
        return {
            "kind": "barkpark_cycle_fleet",
            "workspace_id": scope["workspace_id"],
            "workspace_slug": "default",
            "project_id": scope["project_id"],
            "project_slug": "default",
            "canonical_origin": "https://guerrilla.barkpark.cloud",
            "epic_id": scope["epic_id"],
            "wave_id": scope["wave_id"],
            "wave_revision": cycle_ledger["wave_revision"],
        }

    def scope_fence(self, cycle_ledger, fleet):
        authority = self.authority(cycle_ledger)
        unsigned = {
            "version": MODULE.B1_SCOPE_FENCE_VERSION,
            **{key: authority[key] for key in (
                "workspace_id", "project_id", "epic_id", "wave_id", "wave_revision"
            )},
            "inventory_digest": cycle_ledger["inventory_digest"],
            "plan_digest": cycle_ledger["plan_digest"],
            "reconciliation_digest": cycle_ledger["reconciliation_digest"],
            "fleet_digest": MODULE.EPIC.canonical_digest(fleet),
        }
        return {**unsigned, "receipt_digest": MODULE.EPIC.canonical_digest(unsigned)}

    def args(
        self,
        task=None,
        paper=None,
        phase="build",
        require_debrief=False,
        ledger=None,
        include_ledger=True,
    ):
        task = task or self.task
        paper = paper or self.paper
        benchmark_ledger = ledger or self.ledger(task, paper)
        cycle_ledger = next(
            (block["cycle_ledger"] for block in paper["body"]["blocks"] if "cycle_ledger" in block),
            {},
        )
        authority = self.authority(cycle_ledger) if isinstance(cycle_ledger.get("scope"), dict) else {}
        return argparse.Namespace(
            task=None,
            task_json=self.write("task.json", task),
            paper=None,
            paper_json=self.write("paper.json", paper),
            cycle_json=self.write(
                "cycle.json",
                {
                    "cycle_ledger": cycle_ledger,
                    "fleet": self.fleet(paper),
                    "authority": authority,
                },
            ),
            worker="legendary-lead",
            phase=phase,
            require_debrief=require_debrief,
            fleet_ledger_json=(
                self.write("fleet-ledger.json", MODULE.EPIC.canonical_json(benchmark_ledger))
                if include_ledger
                else None
            ),
            wish_file=self.write("wish.txt", "repair every unreadable Paper\n"),
            pr_body=self.write("pr.md", "Summary\n\nTask: legendary-slice-1\n"),
            workspace="default",
            project="default",
        )

    def fleet(self, paper):
        return next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)

    def test_valid_five_scale_fixture_passes(self):
        self.assertEqual([], MODULE.validate(self.args()))

    def test_root_campaign_b1_uses_live_cycle_epic_instead_of_parent_goal(self):
        paper = copy.deepcopy(self.paper)
        cycle_ledger = next(
            block["cycle_ledger"]
            for block in paper["body"]["blocks"]
            if "cycle_ledger" in block
        )
        cycle_ledger["scope"]["epic_id"] = self.task["doc"]["doc_id"]
        ledger = self.ledger(paper=paper)

        self.assertEqual([], MODULE.validate(self.args(paper=paper, ledger=ledger)))

    def test_legendary_build_preflight_accepts_prior_fleet_without_future_completions(self):
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

    def test_legendary_build_and_review_require_canonical_ledger(self):
        self.assertIn(
            "build/review preflight requires --fleet-ledger-json",
            MODULE.validate(self.args(include_ledger=False)),
        )

    def test_legendary_build_and_review_reject_unfenced_b1(self):
        for phase in ("build", "review"):
            with self.subTest(phase=phase):
                ledger = self.ledger()
                del ledger["manifest"]["cycle_scope_fence"]
                self.resign_ledger(ledger)
                self.assertIn(
                    "Legendary B1 manifest has no cycle_scope_fence",
                    MODULE.validate(self.args(phase=phase, ledger=ledger)),
                )

    def test_legendary_b1_scope_fence_matches_every_live_authority_pin(self):
        drift = {
            "workspace_id": "foreign-workspace",
            "project_id": "foreign-project",
            "epic_id": "foreign-epic",
            "wave_id": "foreign-wave",
            "wave_revision": "stale-wave-revision",
            "inventory_digest": "d" * 64,
            "plan_digest": "e" * 64,
            "reconciliation_digest": "f" * 64,
            "fleet_digest": "0" * 64,
        }
        for field, value in drift.items():
            with self.subTest(field=field):
                ledger = self.ledger()
                fence = ledger["manifest"]["cycle_scope_fence"]
                fence[field] = value
                unsigned = {key: item for key, item in fence.items() if key != "receipt_digest"}
                fence["receipt_digest"] = MODULE.EPIC.canonical_digest(unsigned)
                self.resign_ledger(ledger)
                self.assertIn(
                    f"Legendary B1 cycle_scope_fence {field} does not match live Cycle authority",
                    MODULE.validate(self.args(ledger=ledger)),
                )

    def test_legendary_b1_scope_fence_receipt_digest_is_verified(self):
        ledger = self.ledger()
        ledger["manifest"]["cycle_scope_fence"]["receipt_digest"] = "0" * 64
        self.resign_ledger(ledger)
        self.assertIn(
            "Legendary B1 cycle_scope_fence receipt_digest mismatch",
            MODULE.validate(self.args(ledger=ledger)),
        )

    def test_legendary_b1_scope_fence_requires_exact_versioned_shape(self):
        mutations = (
            ("version", lambda fence: fence.__setitem__("version", "future-fence-v2")),
            ("shape", lambda fence: fence.__setitem__("unexpected", True)),
        )
        for case, mutate in mutations:
            with self.subTest(case=case):
                ledger = self.ledger()
                fence = ledger["manifest"]["cycle_scope_fence"]
                mutate(fence)
                unsigned = {key: item for key, item in fence.items() if key != "receipt_digest"}
                fence["receipt_digest"] = MODULE.EPIC.canonical_digest(unsigned)
                self.resign_ledger(ledger)
                expected = (
                    f"Legendary B1 cycle_scope_fence version is not {MODULE.B1_SCOPE_FENCE_VERSION}"
                    if case == "version"
                    else "Legendary B1 cycle_scope_fence has an invalid exact shape"
                )
                self.assertIn(expected, MODULE.validate(self.args(ledger=ledger)))

    def test_legendary_b1_scope_fence_requires_cycle_authority_kind(self):
        args = self.args()
        payload = json.loads(Path(args.cycle_json).read_text())
        payload["authority"]["kind"] = "paper_projection"
        args.cycle_json = self.write("wrong-authority-kind.json", payload)
        self.assertIn(
            "live Cycle authority kind is not barkpark_cycle_fleet",
            MODULE.validate(args),
        )

    def test_legendary_b1_attempt_rejects_missing_scope_receipt_after_resign(self):
        ledger = self.ledger()
        attempt = ledger["attempts"][0]
        del attempt["provenance"]["scope_receipt_digest"]
        self.resign_ledger(ledger)
        self.assertIn(
            f"Legendary B1 attempt {attempt['attempt_id']} provenance scope_receipt_digest "
            "does not match the Cycle scope fence",
            MODULE.validate(self.args(ledger=ledger)),
        )

    def test_legendary_b1_attempt_rejects_forged_scope_receipt_after_full_resign(self):
        ledger = self.ledger()
        attempt = ledger["attempts"][0]
        attempt["provenance"]["scope_receipt_digest"] = "f" * 64
        self.resign_ledger(ledger)
        self.assertIn(
            f"Legendary B1 attempt {attempt['attempt_id']} provenance scope_receipt_digest "
            "does not match the Cycle scope fence",
            MODULE.validate(self.args(ledger=ledger)),
        )

    def test_legendary_b1_attempt_rejects_wrong_wave_revision_after_resign(self):
        ledger = self.ledger()
        attempt = ledger["attempts"][0]
        attempt["provenance"]["wave_revision"] = "stale-wave-revision"
        self.resign_ledger(ledger)
        self.assertIn(
            f"Legendary B1 attempt {attempt['attempt_id']} provenance wave_revision "
            "does not match the Cycle scope fence",
            MODULE.validate(self.args(ledger=ledger)),
        )

    def test_legendary_b1_experiment_workspace_matches_live_authority(self):
        ledger = self.ledger()
        ledger["experiment"]["workspace_id"] = "foreign-workspace"
        self.resign_ledger(ledger)
        self.assertIn(
            "Legendary B1 experiment workspace_id does not match live Cycle authority",
            MODULE.validate(self.args(ledger=ledger)),
        )

    def test_legendary_exporter_to_validator_rejects_paper_only_inflation(self):
        ledger = self.ledger()
        ledger["attempts"] = [
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["assignment_id"] != "build-15"
        ]
        for ordinal, attempt in enumerate(ledger["attempts"], start=1):
            attempt["ordinal"] = ordinal
        self.resign_ledger(ledger)
        self.assertIn(
            "fleet ledger build terminal completions do not match the Paper projection",
            MODULE.validate(self.args(ledger=ledger)),
        )

    def test_legendary_exporter_to_validator_requires_high_build_and_review_effort(self):
        ledger = self.ledger()
        build = next(
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["phase"] == "build"
        )
        build["payload"]["fleet_assignment"]["model_reasoning_effort"] = "medium"
        review = next(
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["phase"] == "review"
        )
        review["payload"]["fleet_assignment"]["model_reasoning_effort"] = "medium"
        self.resign_ledger(ledger)
        errors = MODULE.validate(self.args(ledger=ledger))
        self.assertTrue(any("Build effort is not exactly high" in error for error in errors))
        self.assertTrue(any("Review effort is not exactly high" in error for error in errors))

    def test_legendary_ledger_rejects_duplicate_and_non_contiguous_ordinals(self):
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

    def test_legendary_ledger_rejects_independent_attempts_for_one_assignment(self):
        paper = copy.deepcopy(self.paper)
        self.fleet(paper)["experiment"]["failed"] = 1
        ledger = self.ledger(paper=paper)
        original = next(
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["assignment_id"] == "experiment-1"
        )
        independent = copy.deepcopy(original)
        independent["attempt_id"] = "attempt-experiment-1-independent"
        independent["ordinal"] = len(ledger["attempts"]) + 1
        independent["status"] = "failed"
        ledger["attempts"].append(independent)
        self.resign_ledger(ledger)

        self.assertIn(
            "fleet ledger logical assignment 'experiment/experiment-1' attempts do not form one "
            "linear replacement chain with exactly one terminal leaf",
            MODULE.validate(self.args(paper=paper, ledger=ledger)),
        )

    def test_legendary_exporter_to_validator_reconciles_replacement_failure_costs(self):
        paper = copy.deepcopy(self.paper)
        self.fleet(paper)["experiment"]["failed"] = 1
        ledger = self.ledger(paper=paper)
        original = next(
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["assignment_id"] == "experiment-1"
        )
        original["status"] = "timeout"
        replacement = copy.deepcopy(original)
        replacement["attempt_id"] = "attempt-experiment-1-retry"
        replacement["replaces_attempt_id"] = original["attempt_id"]
        replacement["ordinal"] = len(ledger["attempts"]) + 1
        replacement["status"] = "completed"
        ledger["attempts"].append(replacement)
        self.resign_ledger(ledger)
        self.assertEqual([], MODULE.validate(self.args(paper=paper, ledger=ledger)))
        self.assertEqual(1, ledger["summary"]["outcomes"]["timeout"])

    def test_legendary_ledger_rejects_epic_cycle_scope(self):
        ledger = self.ledger()
        ledger["experiment"]["phase"] = "epic"
        self.resign_ledger(ledger)
        self.assertTrue(
            any("expected 'legendary'" in error for error in MODULE.validate(self.args(ledger=ledger)))
        )

    def test_legendary_unrelated_paper_content_preserves_valid_projection(self):
        ledger = self.ledger()
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"].append({"type": "paragraph", "text": "Unrelated context"})
        self.assertEqual([], MODULE.validate(self.args(paper=paper, ledger=ledger)))
    def test_live_cyclefleet_lookup_passes_explicit_workspace_and_project(self):
        args = self.args()
        args.cycle_json = None
        ledger = next(
            block["cycle_ledger"] for block in self.paper["body"]["blocks"]
            if "cycle_ledger" in block
        )
        fleet = self.fleet(self.paper)

        with mock.patch.object(
            MODULE.EPIC,
            "command_json",
            return_value={
                "cycle_ledger": ledger,
                "fleet": fleet,
                "authority": self.authority(ledger),
            },
        ) as command:
            self.assertEqual(
                (ledger, fleet, self.authority(ledger)),
                MODULE._live_cycle_projection(args, ledger),
            )

        command.assert_called_once_with(
            "bp", "--workspace", "default", "--project", "default",
            "cycle", "show", "legendary-1", "wave-1", "-o", "json"
        )

    def test_parser_inherits_cycle_json_exactly_once(self):
        args = MODULE.parser().parse_args(
            [
                "--task-json",
                "task.json",
                "--paper-json",
                "paper.json",
                "--worker",
                "legendary-lead",
                "--cycle-json",
                "cycle.json",
            ]
        )
        self.assertEqual(Path("cycle.json"), args.cycle_json)

    def test_missing_scale_profile_fails(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"] = [block for block in paper["body"]["blocks"] if "scale_profile" not in block]
        self.assertIn("paper has no structured Scale profile record", MODULE.validate(self.args(paper=paper)))

    def test_missing_cycle_ledger_projection_fails(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"] = [block for block in paper["body"]["blocks"] if "cycle_ledger" not in block]
        self.assertIn(
            "paper has no structured CycleFleet ledger projection",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_projection_must_match_live_cyclefleet_authority(self):
        args = self.args()
        live = json.loads(args.cycle_json.read_text(encoding="utf-8"))
        live["cycle_ledger"]["inventory_digest"] = "f" * 64
        args.cycle_json = self.write("drifted-cycle.json", live)
        self.assertIn(
            "paper CycleFleet projection does not exactly match the live ledger authority",
            MODULE.validate(args),
        )

    def test_fleet_projection_must_match_live_cyclefleet_authority(self):
        args = self.args()
        live = json.loads(args.cycle_json.read_text(encoding="utf-8"))
        live["fleet"]["review"]["completed"] = 14
        args.cycle_json = self.write("drifted-fleet-cycle.json", live)
        self.assertIn(
            "paper Agent fleet does not exactly match the live CycleFleet fleet",
            MODULE.validate(args),
        )

    def test_complete_scale_profile_must_match_live_contract_and_capacity(self):
        drift_cases = {
            "target_surfaces": ["Studio"],
            "concurrency_width": 4,
            "excluded_inventory": [{"unit_id": "paper-1", "reason": "wrong"}],
            "quality_rubric": {"reader_visibility": "drifted"},
            "failure_threshold": 0.1,
            "proven_batch_capacity": 19,
        }

        for field, value in drift_cases.items():
            with self.subTest(field=field):
                paper = copy.deepcopy(self.paper)
                profile = next(
                    block["scale_profile"]
                    for block in paper["body"]["blocks"]
                    if "scale_profile" in block
                )
                profile[field] = value
                self.assertIn(
                    "paper Scale profile does not exactly match the live CycleFleet scale contract and capacity",
                    MODULE.validate(self.args(paper=paper)),
                )

    def test_unsealed_strategize_accepts_null_copied_capacity_fields(self):
        paper = copy.deepcopy(self.paper)
        profile = next(
            block["scale_profile"]
            for block in paper["body"]["blocks"]
            if "scale_profile" in block
        )
        profile.pop("proven_batch_capacity")
        ledger = next(
            block["cycle_ledger"]
            for block in paper["body"]["blocks"]
            if "cycle_ledger" in block
        )
        ledger["capacity"] = {
            "sealed": False,
            "chosen_format": None,
            "proven_batch_capacity": None,
            "failure_rate": None,
            "failure_threshold": None,
            "golden_fixtures": None,
            "quality_rubric": None,
        }

        self.assertEqual([], MODULE.validate(self.args(paper=paper, phase="strategize")))

    def test_unsealed_capacity_rejects_premature_copied_contract_fields(self):
        drift_cases = {
            "chosen_format": "paper-v1",
            "proven_batch_capacity": 20,
            "failure_rate": 0.0,
            "failure_threshold": 0.1,
            "golden_fixtures": ["paper://fixtures/good"],
            "quality_rubric": {"drifted": True},
        }

        for field, value in drift_cases.items():
            with self.subTest(field=field):
                paper = copy.deepcopy(self.paper)
                ledger = next(
                    block["cycle_ledger"]
                    for block in paper["body"]["blocks"]
                    if "cycle_ledger" in block
                )
                ledger["capacity"]["sealed"] = False
                ledger["capacity"][field] = value

                self.assertIn(
                    f"live CycleFleet unsealed capacity {field} is not null",
                    MODULE.validate(self.args(paper=paper, phase="strategize")),
                )

    def test_sealed_capacity_must_retain_frozen_contract_fields(self):
        drift_cases = {
            "failure_threshold": 0.1,
            "quality_rubric": {"drifted": True},
        }

        for field, value in drift_cases.items():
            with self.subTest(field=field):
                args = self.args()
                live = json.loads(args.cycle_json.read_text(encoding="utf-8"))
                live["cycle_ledger"]["capacity"][field] = value
                args.cycle_json = self.write(f"drifted-{field}.json", live)
                self.assertIn(
                    f"live CycleFleet capacity {field} drifted from Scale contract",
                    MODULE.validate(args),
                )

    def test_decide_requires_sealed_capacity(self):
        paper = copy.deepcopy(self.paper)
        ledger = next(
            block["cycle_ledger"]
            for block in paper["body"]["blocks"]
            if "cycle_ledger" in block
        )
        ledger["capacity"]["sealed"] = False

        self.assertIn(
            "live CycleFleet capacity is not sealed before decide",
            MODULE.validate(self.args(paper=paper, phase="decide")),
        )

    def test_cycle_ledger_must_be_reader_visible(self):
        paper = copy.deepcopy(self.paper)
        block = next(block for block in paper["body"]["blocks"] if "cycle_ledger" in block)
        block["content"] = []
        self.assertIn(
            "cycle ledger callout has no complete reader-visible reconciliation summary",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_cycle_ledger_visible_summary_requires_terminal_counts(self):
        paper = copy.deepcopy(self.paper)
        block = next(block for block in paper["body"]["blocks"] if "cycle_ledger" in block)
        block["content"][0]["value"] = (
            "Legendary CycleFleet wave wave-rev-1: 300 inventoried, 300 assigned; "
            "exact reconciliation true."
        )
        self.assertIn(
            "cycle ledger callout has no complete reader-visible reconciliation summary",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_build_rejects_duplicate_unit_ownership(self):
        paper = copy.deepcopy(self.paper)
        ledger = next(block["cycle_ledger"] for block in paper["body"]["blocks"] if "cycle_ledger" in block)
        ledger["duplicate_assignment_unit_ids"] = ["paper-42"]
        self.assertIn("cycle ledger has multiply assigned units", MODULE.validate(self.args(paper=paper)))

    def test_review_requires_exact_terminal_reconciliation(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"].append({"type": "heading", "text": "Debrief"})
        ledger = next(block["cycle_ledger"] for block in paper["body"]["blocks"] if "cycle_ledger" in block)
        ledger.update({"shipped_count": 299, "unaccounted_unit_ids": ["paper-300"], "exact": False})
        errors = MODULE.validate(self.args(paper=paper, phase="review", require_debrief=True))
        self.assertIn("cycle ledger has unaccounted units", errors)
        self.assertIn("cycle ledger exact flag is not true", errors)

    def test_review_debrief_requires_complete_planned_fleet(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"].append({"type": "heading", "text": "Debrief"})
        ledger = next(block["cycle_ledger"] for block in paper["body"]["blocks"] if "cycle_ledger" in block)
        ledger["fleet_complete"] = False
        errors = MODULE.validate(self.args(paper=paper, phase="review", require_debrief=True))
        self.assertIn("cycle ledger fleet_complete flag is not true", errors)

    def test_malformed_experiment_count_is_a_validation_error(self):
        paper = copy.deepcopy(self.paper)
        ledger = next(block["cycle_ledger"] for block in paper["body"]["blocks"] if "cycle_ledger" in block)
        ledger["experiment"]["round_counts"]["baseline"] = "3"
        self.assertIn(
            "cycle ledger experiment round baseline count is invalid",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_wrong_multiplier_fails(self):
        paper = copy.deepcopy(self.paper)
        profile = next(block["scale_profile"] for block in paper["body"]["blocks"] if "scale_profile" in block)
        profile["minimum_multiplier"] = 4
        self.assertIn("scale profile minimum_multiplier is not 5", MODULE.validate(self.args(paper=paper)))

    def test_build_formula_scales_above_fifteen(self):
        paper = copy.deepcopy(self.paper)
        profile = next(block["scale_profile"] for block in paper["body"]["blocks"] if "scale_profile" in block)
        profile.update({"unit_count": 400, "proven_batch_capacity": 20, "planned_build_assignments": 20})
        ledger = next(block["cycle_ledger"] for block in paper["body"]["blocks"] if "cycle_ledger" in block)
        ledger.update({"inventory_count": 400, "assigned_count": 400, "shipped_count": 400, "planned_builders": 20})
        ledger["scale_contract"]["unit_count"] = 400
        ledger_block = next(block for block in paper["body"]["blocks"] if "cycle_ledger" in block)
        ledger_block["content"][0]["value"] = (
            "Legendary CycleFleet wave wave-rev-1: 400 inventoried, 400 assigned, "
            "400 shipped, 0 stalled, 0 excluded; exact reconciliation true."
        )
        build = self.fleet(paper)["build"]
        build["planned"] = 20
        for index in range(15, 20):
            build["assignments"].append(
                {
                    "id": f"build-{index + 1}",
                    "agent_type": "legendary-builder",
                    "status": "completed",
                    "evidence": f"paper://build/{index + 1}",
                }
            )
        build.update({"started": 20, "completed": 20, "missing": 0})
        self.assertEqual([], MODULE.validate(self.args(paper=paper)))

    def test_build_formula_mismatch_fails(self):
        paper = copy.deepcopy(self.paper)
        profile = next(block["scale_profile"] for block in paper["body"]["blocks"] if "scale_profile" in block)
        profile.update({"unit_count": 400, "proven_batch_capacity": 20, "planned_build_assignments": 15})
        self.assertIn(
            "scale profile planned_build_assignments is not evaluated formula result 20",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_decide_requires_all_experiments(self):
        paper = copy.deepcopy(self.paper)
        experiment = self.fleet(paper)["experiment"]
        experiment["assignments"] = experiment["assignments"][:-1]
        experiment.update({"completed": 14, "missing": 1})
        self.assertIn(
            "fleet experiment requires 15 completed typed assignments before decide",
            MODULE.validate(self.args(paper=paper, phase="decide")),
        )

    def test_additional_experiments_are_forbidden_in_the_same_wave(self):
        paper = copy.deepcopy(self.paper)
        experiment = self.fleet(paper)["experiment"]
        experiment["assignments"].append(
            {
                "id": "experiment-16",
                "agent_type": "legendary-experimenter",
                "status": "completed",
                "evidence": "paper://experiment/16",
            }
        )
        experiment.update({"started": 16, "completed": 16, "missing": 0})
        self.assertIn(
            "fleet experiment exceeds its exact 15-assignment contract",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_additional_review_is_forbidden_in_the_same_wave(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"].append({"type": "heading", "text": "Debrief"})
        review = self.fleet(paper)["review"]
        review["assignments"].append(
            {
                "id": "review-16",
                "agent_type": "code-reviewer",
                "status": "completed",
                "evidence": "paper://review/16",
            }
        )
        review.update({"started": 16, "completed": 16, "missing": 0})
        self.assertIn(
            "fleet review exceeds its exact 15-assignment contract",
            MODULE.validate(self.args(paper=paper, phase="review", require_debrief=True)),
        )

    def test_wrong_phase_effort_is_forbidden(self):
        paper = copy.deepcopy(self.paper)
        self.fleet(paper)["build"]["effort"] = "high"
        self.assertIn("fleet build effort is not medium", MODULE.validate(self.args(paper=paper)))

    def test_contract_pins_numeric_and_builder_heavy_rules(self):
        skill = (SCRIPT.parents[1] / "SKILL.md").read_text(encoding="utf-8")
        fleet = (SCRIPT.parents[1] / "references" / "fleet-contract.md").read_text(encoding="utf-8")
        scale = (SCRIPT.parents[1] / "references" / "scale-contract.md").read_text(encoding="utf-8")
        builder = (SCRIPT.parents[3] / "agents" / "legendary-builder.toml").read_text(encoding="utf-8")
        experimenter = (SCRIPT.parents[3] / "agents" / "legendary-experimenter.toml").read_text(encoding="utf-8")
        self.assertIn("exactly five times", skill)
        self.assertIn("60 Survey", skill)
        self.assertIn("30 Verify", skill)
        self.assertIn("at least 15", skill)
        self.assertIn("minimum total is 135", fleet)
        self.assertIn("--fleet-ledger-json", fleet)
        self.assertIn(
            "All Legendary Build and Review attempts use `model_reasoning_effort: high`",
            fleet,
        )
        self.assertIn("Every attempt stays in cost and outcome denominators", fleet)
        self.assertIn('model_reasoning_effort = "medium"', builder)
        self.assertIn('name = "legendary-experimenter"', experimenter)
        self.assertIn("open a new immutable wave", skill)
        self.assertIn("Never recompute or reopen Experiment inside the sealed wave", scale)


if __name__ == "__main__":
    unittest.main()
