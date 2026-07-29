import json
from pathlib import Path
import tempfile
import unittest

import candidate


class CandidateUnitTest(unittest.TestCase):
    def fixture(self):
        return {
            "id": "synthetic",
            "_rev": "rev-1",
            "title": "Synthetic title",
            "source": {
                "kind": "blocks",
                "blocks": [
                    {
                        "id": "a",
                        "type": "paragraph",
                        "text": "A very long authored token abcdefghijklmnopqrstuvwxyz.",
                    },
                    {
                        "id": "b",
                        "type": "image",
                        "alt": "Informative image",
                        "caption": "Caption text",
                    },
                ],
            },
        }

    def test_canonical_source_is_exact_and_all_projections_pass(self):
        built = candidate.build_candidate(self.fixture(), "paper:synthetic")
        self.assertEqual(
            built["authored"]["portable_doc"]["blocks"],
            self.fixture()["source"]["blocks"],
        )
        studio = candidate.render_studio(built)
        tui80 = candidate.render_tui(built, 80)
        tui40 = candidate.render_tui(built, 40)
        email = candidate.render_email(built)
        cli_api = candidate.canonical_bytes(built)
        result = candidate.verify_candidate(
            built, studio, tui80, tui40, email, cli_api
        )
        self.assertTrue(result["hard_gate_pass"], result)
        self.assertEqual(result["studio_structural_completeness"]["logical_h1_count"], 1)
        self.assertEqual(result["email_safety"]["logical_h1_count"], 1)

    def test_hard_wrap_respects_unicode_display_width(self):
        value = "wide 界界 plus abcdefghijklmnopqrstuvwxyz"
        for width in (10, 40, 80):
            lines = candidate.hard_wrap(value, width)
            self.assertTrue(lines)
            self.assertLessEqual(
                max(candidate.display_width(line) for line in lines), width
            )

    def test_canonical_cli_api_round_trip_is_byte_stable(self):
        built = candidate.build_candidate(self.fixture(), "paper:synthetic")
        raw = candidate.canonical_bytes(built)
        decoded = json.loads(raw)
        self.assertEqual(candidate.canonical_bytes(decoded), raw)

    def test_missing_or_invalid_block_type_is_rejected(self):
        malformed = self.fixture()
        malformed["source"]["blocks"][0]["type"] = ""
        with self.assertRaisesRegex(ValueError, "nonempty string type"):
            candidate.build_candidate(malformed, "paper:malformed")

    def test_typed_tree_is_counted_without_truncation(self):
        built = candidate.build_candidate(self.fixture(), "paper:synthetic")
        stats = built["authored"]["typed_tree_stats"]
        self.assertEqual(stats["typed_nodes"], 2)
        self.assertEqual(stats["invalid_typed_nodes"], 0)
        self.assertLess(stats["max_json_depth"], 64)

    def test_verify_output_replays_generated_metrics_when_present(self):
        artifact_root = Path(__file__).with_name("artifacts")
        if not (artifact_root / "run-summary.json").exists():
            self.skipTest("generated corpus artifacts not present yet")
        result = candidate.verify_output(artifact_root)
        self.assertEqual(result["status"], "PASS")


if __name__ == "__main__":
    unittest.main()
