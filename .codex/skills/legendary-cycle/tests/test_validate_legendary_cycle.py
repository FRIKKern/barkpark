#!/usr/bin/env python3

import argparse
import copy
import importlib.util
import json
import tempfile
import unittest
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
                    "wave_paper": "legendary-paper-1",
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
                "planned": planned,
                "started": planned,
                "completed": planned,
                "failed": 0,
                "missing": 0,
                "assignments": assignments,
            }
        self.paper = {
            "_id": "legendary-paper-1",
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
        task = task or self.task
        paper = MODULE.EPIC.paper_doc(paper or self.paper)
        fields = MODULE.EPIC.task_fields(MODULE.EPIC.task_doc(task))
        fleet = MODULE.EPIC.paper_fleet(paper)
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
                        "provenance": {"source": "legendary validator fixture"},
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
                "workspace_id": "workspace-fixture",
                "epic_id": fields.get("parent_id"),
                "wave_id": paper["_id"],
                "experiment_id": "legendary-fleet-fixture",
                "phase": "legendary",
                "protocol_version": 1,
            },
            "manifest": {
                "fleet_contract": {
                    "version": 1,
                    "paper_fleet_digest": MODULE.EPIC.canonical_digest(fleet),
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
        phase="build",
        require_debrief=False,
        ledger=None,
        include_ledger=True,
    ):
        task = task or self.task
        paper = paper or self.paper
        ledger = ledger or self.ledger(task, paper)
        return argparse.Namespace(
            task=None,
            task_json=self.write("task.json", task),
            paper=None,
            paper_json=self.write("paper.json", paper),
            worker="legendary-lead",
            phase=phase,
            require_debrief=require_debrief,
            fleet_ledger_json=(
                self.write("fleet-ledger.json", MODULE.EPIC.canonical_json(ledger))
                if include_ledger
                else None
            ),
            wish_file=self.write("wish.txt", "repair every unreadable Paper\n"),
            pr_body=self.write("pr.md", "Summary\n\nTask: legendary-slice-1\n"),
        )

    def fleet(self, paper):
        return next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)

    def test_valid_five_scale_fixture_passes(self):
        self.assertEqual([], MODULE.validate(self.args()))

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

    def test_legendary_exporter_to_validator_rejects_paper_only_inflation(self):
        ledger = self.ledger()
        ledger["attempts"] = [
            attempt
            for attempt in ledger["attempts"]
            if attempt["payload"]["fleet_assignment"]["assignment_id"] != "build-15"
        ]
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

    def test_missing_scale_profile_fails(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"] = [block for block in paper["body"]["blocks"] if "scale_profile" not in block]
        self.assertIn("paper has no structured Scale profile record", MODULE.validate(self.args(paper=paper)))

    def test_wrong_multiplier_fails(self):
        paper = copy.deepcopy(self.paper)
        profile = next(block["scale_profile"] for block in paper["body"]["blocks"] if "scale_profile" in block)
        profile["minimum_multiplier"] = 4
        self.assertIn("scale profile minimum_multiplier is not 5", MODULE.validate(self.args(paper=paper)))

    def test_build_formula_scales_above_fifteen(self):
        paper = copy.deepcopy(self.paper)
        profile = next(block["scale_profile"] for block in paper["body"]["blocks"] if "scale_profile" in block)
        profile.update({"unit_count": 400, "proven_batch_capacity": 20, "planned_build_assignments": 20})
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

    def test_additional_experiments_require_complete_wave(self):
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
            "fleet experiment contains an incomplete additional wave",
            MODULE.validate(self.args(paper=paper)),
        )

    def test_review_requires_complete_fifteen_assignment_repeat(self):
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
            "fleet review contains an incomplete repeated review fleet",
            MODULE.validate(self.args(paper=paper, phase="review", require_debrief=True)),
        )

    def test_contract_pins_numeric_and_builder_heavy_rules(self):
        skill = (SCRIPT.parents[1] / "SKILL.md").read_text(encoding="utf-8")
        fleet = (SCRIPT.parents[1] / "references" / "fleet-contract.md").read_text(encoding="utf-8")
        builder = (SCRIPT.parents[3] / "agents" / "legendary-builder.toml").read_text(encoding="utf-8")
        experimenter = (SCRIPT.parents[3] / "agents" / "legendary-experimenter.toml").read_text(encoding="utf-8")
        self.assertIn("exactly five times", skill)
        self.assertIn("60 Survey", skill)
        self.assertIn("30 Verify", skill)
        self.assertIn("at least 15", skill)
        self.assertIn("minimum total is 135", fleet)
        self.assertIn("--fleet-ledger-json", fleet)
        self.assertIn("All Legendary Build attempts use `model_reasoning_effort: high`", fleet)
        self.assertIn("Every attempt stays in cost and outcome denominators", fleet)
        self.assertIn('model_reasoning_effort = "medium"', builder)
        self.assertIn('name = "legendary-experimenter"', experimenter)


if __name__ == "__main__":
    unittest.main()
