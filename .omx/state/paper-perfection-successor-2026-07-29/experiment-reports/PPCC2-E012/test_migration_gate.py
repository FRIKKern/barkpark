#!/usr/bin/env python3
import copy
import json
from pathlib import Path
import unittest
import migration_gate as gate

FIXTURES = Path(__file__).parent / "inputs" / "fixtures"

class MigrationGateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.control = gate.strict_loads(next(iter(sorted(FIXTURES.glob("*/source.json")))).read_bytes())

    def test_strict_json_rejects_duplicate_and_nonfinite(self):
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}'):
            with self.assertRaises(ValueError): gate.strict_loads(raw)

    def test_migration_is_idempotent_and_preserves_authored_blocks(self):
        first = gate.migration_envelope(self.control, "paper:control")
        second = gate.migration_envelope(self.control, "paper:control")
        self.assertEqual(gate.canonical_bytes(first), gate.canonical_bytes(second))
        self.assertEqual(first["authored"]["portable_doc"]["blocks"], self.control["source"]["blocks"])
        self.assertEqual(first["source_snapshot"], self.control)

    def test_hostile_shapes_quarantine_with_rollback(self):
        for name, payload in gate.hostile_payloads(self.control).items():
            envelope = gate.migration_envelope(payload, "hostile:" + name)
            self.assertEqual(envelope["status"], "quarantined", name)
            self.assertTrue(envelope["quarantine"]["raw_payload_preserved"], name)
            self.assertEqual(envelope["source_snapshot"], payload, name)

    def test_safe_href_remains_reader_visible(self):
        value = copy.deepcopy(self.control)
        value["source"]["blocks"].append({"id":"href-control", "type":"action", "label":"Open", "href":"https://example.invalid/safe"})
        env = gate.migration_envelope(value, "paper:href-control")
        detail, outputs = gate.verify(env)
        self.assertTrue(detail["hard_gate_pass"])
        for surface in ("studio", "tui80", "tui40", "email"):
            self.assertIn(b"https://example.invalid/safe", outputs[surface])

    def test_semantic_headings_and_width(self):
        env = gate.migration_envelope(self.control, "paper:control")
        detail, outputs = gate.verify(env)
        self.assertEqual(detail["heading_blocks"], detail["studio_semantic_heading_count"])
        self.assertLessEqual(detail["tui80_max_display_width"], 80)
        self.assertLessEqual(detail["tui40_max_display_width"], 40)
        self.assertNotIn(b"<details", outputs["email"])

if __name__ == "__main__": unittest.main()
