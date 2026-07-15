#!/usr/bin/env python3

import hashlib
import json
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).parents[4]
ROSTER = ROOT / ".omx" / "state" / "legendary-survey-roster.json"


class LegendarySurveyRosterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.roster = json.loads(ROSTER.read_text(encoding="utf-8"))
        cls.assignments = cls.roster["assignments"]
        cls.by_id = {assignment["id"]: assignment for assignment in cls.assignments}

    def test_roster_has_exact_canonical_ids_slots_and_hash(self):
        expected_ids = [f"LQ-P{index:02d}" for index in range(1, 19)]
        expected_ids += [f"LQ-T{index:02d}" for index in range(1, 25)]
        expected_ids += [f"LQ-X{index:02d}" for index in range(1, 13)]
        actual_ids = [assignment["id"] for assignment in self.assignments]
        actual_slots = [assignment["fleet_slot"] for assignment in self.assignments]

        self.assertEqual("legendary-survey-roster/v1", self.roster["schema_version"])
        self.assertEqual(expected_ids, self.roster["global_contract"]["all_assignment_ids"])
        self.assertCountEqual(expected_ids, actual_ids)
        self.assertEqual(len(actual_ids), len(set(actual_ids)))
        self.assertCountEqual(range(7, 61), actual_slots)
        self.assertEqual(len(actual_slots), len(set(actual_slots)))

        digest = hashlib.sha256(("\n".join(expected_ids) + "\n").encode()).hexdigest()
        self.assertEqual(digest, self.roster["hashes"]["canonical_assignment_ids_sha256"])

        assignments_json = json.dumps(
            self.assignments,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        assignments_digest = hashlib.sha256(assignments_json.encode("utf-8")).hexdigest()
        self.assertEqual(assignments_digest, self.roster["hashes"]["canonical_assignments_sha256"])

    def test_each_wave_has_six_paper_eight_task_and_four_cross_surface_assignments(self):
        expected_lane_counts = {"paper": 6, "task": 8, "cross_surface": 4}
        for wave, first_slot in (("03", 7), ("04", 25), ("05", 43)):
            assignments = [assignment for assignment in self.assignments if assignment["wave"] == wave]
            self.assertEqual(18, len(assignments), wave)
            self.assertEqual(
                expected_lane_counts,
                Counter(assignment["lane"] for assignment in assignments),
                wave,
            )
            self.assertCountEqual(range(first_slot, first_slot + 18), [a["fleet_slot"] for a in assignments])

    def test_wave_03_batch_matches_the_manifest(self):
        expected = {f"LQ-P{index:02d}" for index in range(1, 7)}
        expected |= {f"LQ-T{index:02d}" for index in range(1, 9)}
        expected |= {f"LQ-X{index:02d}" for index in range(1, 5)}
        actual = {assignment["id"] for assignment in self.assignments if assignment["wave"] == "03"}
        self.assertEqual(expected, actual)

    def test_assignments_have_executable_lane_specific_contracts(self):
        common = {"id", "fleet_slot", "wave", "title", "scope", "validation", "risks", "stop_condition"}
        lane_fields = {
            "paper": {"inputs", "commands_or_probes", "expected_accounting", "deliverable"},
            "task": {"deterministic_membership", "probes"},
            "cross_surface": {"inputs", "commands_or_probes", "expected_accounting", "deliverable"},
        }
        for assignment in self.assignments:
            for field in common | lane_fields[assignment["lane"]]:
                self.assertIn(field, assignment, f"{assignment['id']} missing {field}")
                self.assertNotIn(assignment[field], (None, "", [], {}), f"{assignment['id']} has empty {field}")

    def test_intentional_overlap_pairs_are_reciprocal(self):
        for assignment in self.assignments:
            for paired_id in assignment.get("paired_assignment_ids", []):
                self.assertIn(paired_id, self.by_id, f"{assignment['id']} pairs unknown {paired_id}")
                reverse = self.by_id[paired_id].get("paired_assignment_ids", [])
                self.assertIn(
                    assignment["id"],
                    reverse,
                    f"{assignment['id']} -> {paired_id} is not reciprocal",
                )

    def test_embedded_validation_checklist_matches_recomputed_counts(self):
        checks = {check["name"]: check for check in self.roster["validation_checklist"]}
        recomputed = {
            "assignment_count": len(self.assignments),
            "unique_ids": len(self.by_id),
            "unique_fleet_slots": len({assignment["fleet_slot"] for assignment in self.assignments}),
            "lane_counts": dict(Counter(assignment["lane"] for assignment in self.assignments)),
            "wave_counts": dict(Counter(assignment["wave"] for assignment in self.assignments)),
        }
        for name, actual in recomputed.items():
            self.assertEqual("PASS", checks[name]["status"], name)
            self.assertEqual(checks[name]["expected"], checks[name]["actual"], name)
            self.assertEqual(checks[name]["actual"], actual, name)


if __name__ == "__main__":
    unittest.main()
