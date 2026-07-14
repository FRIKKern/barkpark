#!/usr/bin/env python3

import argparse
import copy
import importlib.util
import json
import tempfile
import unittest
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
                "planned": planned,
                "started": planned,
                "completed": planned,
                "failed": 0,
                "missing": 0,
                "assignments": assignments,
            }
        self.paper = {
            "_id": "paper-1",
            "_draft": False,
            "body": {
                "version": 1,
                "blocks": [
                    {"type": "heading", "text": "User wish"},
                    {"type": "quote", "text": "make Codex task obsessed"},
                    {"type": "heading", "text": "Strategic direction"},
                    {"type": "heading", "text": "Agent fleet"},
                    {"type": "callout", "title": "COMPLETE", "fleet": fleet},
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

    def args(
        self,
        task=None,
        paper=None,
        pr_body="Summary\n\nTask: slice-1\n",
        phase="build",
        require_debrief=False,
        include_wish=True,
    ):
        return argparse.Namespace(
            task=None,
            task_json=self.write("task.json", task or self.task),
            paper=None,
            paper_json=self.write("paper.json", paper or self.paper),
            worker="codex-lead",
            phase=phase,
            require_debrief=require_debrief,
            wish_file=self.write("wish.txt", "make Codex task obsessed") if include_wish else None,
            pr_body=self.write("pr.md", pr_body),
        )

    def test_valid_fixture_passes(self):
        self.assertEqual([], MODULE.validate(self.args()))

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

    def test_post_review_gate_accepts_complete_repeated_review_wave(self):
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
        self.assertEqual([], MODULE.validate(self.args(paper=paper, phase="review", require_debrief=True)))

    def test_post_review_gate_rejects_incomplete_repeated_review_wave(self):
        paper = copy.deepcopy(self.paper)
        paper["body"]["blocks"].append({"type": "heading", "text": "Debrief"})
        fleet = next(block["fleet"] for block in paper["body"]["blocks"] if "fleet" in block)
        fleet["review"]["assignments"].append(
            {
                "id": "review-2-1",
                "agent_type": "code-reviewer",
                "status": "completed",
                "evidence": "paper://review/round-2/reviewer-1",
            }
        )
        fleet["review"].update({"started": 4, "completed": 4, "missing": 0})
        self.assertIn(
            "fleet review contains an incomplete repeated review wave",
            MODULE.validate(self.args(paper=paper, phase="review", require_debrief=True)),
        )

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
        self.assertIn("Never overwrite earlier review evidence", fleet)


if __name__ == "__main__":
    unittest.main()
