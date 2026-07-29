#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import unittest

import attack_candidates as attack


class AttackHarnessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        source = json.loads(
            (
                attack.INPUTS
                / "PPCC2-E005"
                / "source-fixtures.json"
            ).read_text(encoding="utf-8")
        )["documents"][0]
        cls.hostile = attack.hostile_document(source)

    def test_hostile_document_is_copy_and_contains_all_attack_shapes(self) -> None:
        types = [block.get("type") for block in self.hostile["blocks"][-6:]]
        self.assertEqual(
            types, ["paragraph", "table", "code", "action", "action", "section"]
        )
        raw = json.dumps(self.hostile, ensure_ascii=False)
        for marker in attack.ATTACK_MARKERS:
            self.assertIn(marker, raw)
        self.assertIn(attack.SAFE_URL, raw)
        self.assertIn(attack.UNSAFE_URL, raw)

    def test_html_probe_detects_active_script_and_unsafe_attributes(self) -> None:
        probe = attack.probe_html(
            '<h1>x</h1><script>x()</script>'
            '<a href="javascript:alert(1)" onclick="x()">x</a>'
        )
        self.assertEqual(probe["h1_count"], 1)
        self.assertEqual(probe["script_count"], 1)
        self.assertEqual(len(probe["unsafe_url_attributes"]), 1)
        self.assertEqual(probe["event_attributes"], ["onclick"])

    def test_html_probe_accepts_escaped_hostile_text(self) -> None:
        probe = attack.probe_html(
            "<h1>x</h1><p>&lt;script&gt;literal&lt;/script&gt;</p>"
            '<a href="https://example.test/">safe</a>'
        )
        self.assertEqual(probe["script_count"], 0)
        self.assertEqual(probe["unsafe_url_attributes"], [])
        self.assertIn("<script>literal</script>", probe["text"])

    def test_display_width_counts_wide_and_combining_characters(self) -> None:
        self.assertEqual(attack.display_width("a界e\u0301"), 4)

    def test_marker_order_rejects_reordering(self) -> None:
        ordered = " ".join(attack.ATTACK_MARKERS)
        reversed_markers = " ".join(reversed(attack.ATTACK_MARKERS))
        self.assertTrue(attack.markers_in_order(ordered))
        self.assertFalse(attack.markers_in_order(reversed_markers))


if __name__ == "__main__":
    unittest.main()
