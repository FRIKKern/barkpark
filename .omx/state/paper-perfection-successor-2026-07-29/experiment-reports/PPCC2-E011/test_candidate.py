import copy
import json
from pathlib import Path
import tempfile
import unittest

import candidate


class AccessibilityConvergenceTest(unittest.TestCase):
    def fixture(self):
        return {
            "id": "synthetic",
            "_rev": "rev-1",
            "title": "Synthetic title",
            "source": {
                "kind": "blocks",
                "blocks": [
                    {
                        "id": "h",
                        "type": "heading",
                        "level": 3,
                        "text": "Authored heading",
                    },
                    {
                        "id": "p",
                        "type": "paragraph",
                        "content": [
                            {
                                "type": "text",
                                "value": "A long authored token abcdefghijklmnopqrstuvwxyz.",
                            }
                        ],
                    },
                    {
                        "id": "i",
                        "type": "image",
                        "src": "/media/image.png",
                        "alt": "Informative image",
                        "caption": "Image caption",
                    },
                    {
                        "id": "a",
                        "type": "action",
                        "label": "Read proof",
                        "href": "https://example.test/proof",
                    },
                ],
            },
        }

    def render(self, built):
        studio = candidate.render_studio(built)
        tui80 = candidate.render_tui(built, 80)
        tui40 = candidate.render_tui(built, 40)
        email = candidate.render_email(built)
        cli_api = candidate.canonical_bytes(built)
        return candidate.verify_candidate(
            built, studio, tui80, tui40, email, cli_api
        )

    def test_real_heading_link_image_and_cross_reader_gates(self):
        built = candidate.build_candidate(self.fixture(), "paper:synthetic")
        result = self.render(built)
        self.assertTrue(result["hard_gate_pass"], result)
        self.assertEqual(result["accessibility"]["source_heading_count"], 1)
        self.assertEqual(result["accessibility"]["studio_heading_count"], 1)
        self.assertEqual(result["accessibility"]["email_heading_count"], 1)
        self.assertEqual(result["accessibility"]["source_image_count"], 1)
        self.assertEqual(result["accessibility"]["images_missing_alt"], 0)
        self.assertEqual(result["accessibility"]["safe_link_count"], 1)
        self.assertIn("<h3>Authored heading</h3>", candidate.render_studio(built))
        self.assertIn('href="https://example.test/proof"', candidate.render_email(built))

    def test_missing_alt_and_unsafe_href_degrade_deterministically(self):
        payload = self.fixture()
        payload["source"]["blocks"][2].pop("alt")
        payload["source"]["blocks"][3]["href"] = "javascript:alert(1)"
        first = candidate.build_candidate(payload, "paper:degraded")
        second = candidate.build_candidate(copy.deepcopy(payload), "paper:degraded")
        self.assertEqual(candidate.canonical_bytes(first), candidate.canonical_bytes(second))
        reasons = {item["reason"] for item in first["degradations"]}
        self.assertIn("missing_image_alt", reasons)
        self.assertIn("missing_or_unsafe_link_target", reasons)
        studio = candidate.render_studio(first)
        email = candidate.render_email(first)
        self.assertIn('alt="Image caption"', studio)
        self.assertNotIn('href="javascript:', studio)
        self.assertNotIn("<details", email)
        self.assertTrue(self.render(first)["hard_gate_pass"])

    def test_strict_json_rejects_duplicate_keys_and_non_finite_numbers(self):
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            candidate.strict_loads('{"a":1,"a":2}')
        with self.assertRaisesRegex(ValueError, "non-finite JSON number"):
            candidate.strict_loads('{"a":NaN}')
        with self.assertRaises(ValueError):
            candidate.canonical_bytes({"a": float("inf")})

    def test_malformed_nested_null_is_machine_readable_quarantine(self):
        payload = self.fixture()
        payload["source"]["blocks"][1]["content"].append(None)
        result = candidate.build_or_quarantine(payload, "paper:null")
        self.assertEqual(result["status"], "quarantined")
        self.assertEqual(result["source_path"], "$")
        self.assertIn("nested nulls", result["reason"])
        self.assertEqual(result["raw_payload"], payload)

    def test_duplicate_top_level_identifier_is_quarantined(self):
        payload = self.fixture()
        payload["source"]["blocks"][1]["id"] = "h"
        result = candidate.build_or_quarantine(payload, "paper:duplicate")
        self.assertEqual(result["status"], "quarantined")
        self.assertIn("duplicate block identifier", result["reason"])

    def test_unicode_hard_wrap_never_exceeds_width(self):
        built = candidate.build_candidate(self.fixture(), "paper:synthetic")
        for width in (40, 80):
            output = candidate.render_tui(built, width)
            self.assertLessEqual(
                max(candidate.base.display_width(line) for line in output.splitlines()),
                width,
            )

    def test_generated_output_replays_when_present(self):
        artifact_root = Path(__file__).with_name("artifacts")
        if not (artifact_root / "run-summary.json").exists():
            self.skipTest("generated corpus artifacts not present yet")
        result = candidate.verify_output(artifact_root)
        self.assertEqual(result["status"], "PASS")


if __name__ == "__main__":
    unittest.main()
