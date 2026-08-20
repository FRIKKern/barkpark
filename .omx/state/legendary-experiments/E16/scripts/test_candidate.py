#!/usr/bin/env python3
from __future__ import annotations

import unittest

from candidate import build_capsule, encode_tree, restore_tree, semantic_hash


class LosslessSemanticTreeTests(unittest.TestCase):
    def test_round_trip_preserves_exact_codepoints(self) -> None:
        source = {"body": {"blocks": [{"type": "paragraph", "text": "x" * 7500}]}}
        tree = encode_tree(source)
        restored = restore_tree(tree)
        self.assertEqual(source, restored)
        self.assertEqual(7500, len(restored["body"]["blocks"][0]["text"]))

    def test_nested_table_list_hierarchy_is_retained(self) -> None:
        source = {"body": {"blocks": [{"type": "table", "rows": [[{"type": "bullet_list", "items": [[{"type": "text", "value": "nested"}]]}]]}]}}
        capsule = build_capsule(source, fixture_id="nested", unit_type="adversarial", cohort="nested_lists_tables")
        roles = [event["role"] for event in capsule["semantic_events"]]
        self.assertLess(roles.index("table"), roles.index("list"))
        self.assertEqual(source, restore_tree(capsule["semantic_tree"]))

    def test_status_and_link_roles_are_non_visual(self) -> None:
        source = {"type": "paragraph", "children": [{"type": "link", "href": "https://example.test", "text": "read"}], "lifecycle_status": "blocked"}
        capsule = build_capsule(source, fixture_id="roles", unit_type="task", cohort="probe")
        roles = [event["role"] for event in capsule["semantic_events"]]
        self.assertIn("link", roles)
        self.assertIn("status", roles)

    def test_malformed_and_empty_sources_are_quarantined_without_loss(self) -> None:
        for source in ({"blocks": [{"type": 7, "children": "not-a-list"}]}, {"body": {"blocks": []}}):
            capsule = build_capsule(source, fixture_id="q", unit_type="adversarial", cohort="q")
            self.assertEqual("quarantined_preserved", capsule["status"])
            self.assertEqual(semantic_hash(source), capsule["round_trip_sha256"])

    def test_second_application_is_byte_stable(self) -> None:
        source = {"body": "# Heading\n\n- item"}
        first = build_capsule(source, fixture_id="x", unit_type="paper", cohort="markdown")
        second = build_capsule(first, fixture_id="x", unit_type="paper", cohort="markdown")
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main(verbosity=2)

