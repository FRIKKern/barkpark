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

    def args(self, task=None, paper=None, phase="build", require_debrief=False):
        return argparse.Namespace(
            task=None,
            task_json=self.write("task.json", task or self.task),
            paper=None,
            paper_json=self.write("paper.json", paper or self.paper),
            worker="legendary-lead",
            phase=phase,
            require_debrief=require_debrief,
            wish_file=self.write("wish.txt", "repair every unreadable Paper\n"),
            pr_body=self.write("pr.md", "Summary\n\nTask: legendary-slice-1\n"),
        )

    def fleet(self, paper):
        return next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)

    def test_valid_five_scale_fixture_passes(self):
        self.assertEqual([], MODULE.validate(self.args()))

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
        self.assertIn('model_reasoning_effort = "medium"', builder)
        self.assertIn('name = "legendary-experimenter"', experimenter)


if __name__ == "__main__":
    unittest.main()
