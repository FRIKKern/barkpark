#!/usr/bin/env python3
"""Focused unit tests for the E05 semantic boundary and adapters."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from core import ADAPTERS, PAPER_IDS, email_adapter, public_adapter, semantic_core, studio_adapter, tui_adapter

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent.parent / "E01" / "raw" / "paper_json"


class CompatibilityCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = (SOURCE / "CCH29.json").read_bytes()
        cls.source = json.loads(cls.raw)
        cls.core = semantic_core(cls.raw)

    def test_all_pinned_sources_build(self) -> None:
        self.assertEqual(set(PAPER_IDS), {path.stem for path in SOURCE.glob("*.json")})
        for paper in PAPER_IDS:
            self.assertEqual(semantic_core((SOURCE / f"{paper}.json").read_bytes())["source_receipt"]["bytes"],
                             (SOURCE / f"{paper}.json").stat().st_size)

    def test_semantic_blocks_are_lossless(self) -> None:
        self.assertEqual(self.source["blocks"], self.core["value"]["blocks"])
        self.assertEqual(len(self.core["value"]["blocks"]), 252)

    def test_identity_domains_are_distinct(self) -> None:
        receipt = self.core["identity_receipt"]
        self.assertTrue(receipt["domains_distinct"])
        self.assertEqual(len({receipt[k] for k in ("document_identity", "release_identity", "cache_identity", "cycle_identity")}), 4)

    def test_adapters_are_deterministic_and_nonblank(self) -> None:
        for adapter in ADAPTERS.values():
            self.assertEqual(adapter(self.core), adapter(semantic_core(self.raw)))
            self.assertTrue(adapter(self.core).strip())

    def test_public_escapes_authored_markup(self) -> None:
        probe = dict(self.core)
        probe["value"] = json.loads(json.dumps(self.core["value"]))
        probe["value"]["blocks"] = [{"id": "x", "type": "paragraph", "content": [{"type": "text", "value": "<script>alert(1)</script>"}]}]
        rendered = public_adapter(probe).decode()
        self.assertNotIn("<script>", rendered)
        self.assertIn("&lt;script&gt;", rendered)

    def test_object_link_marks_are_safe_and_semantic(self) -> None:
        probe = dict(self.core)
        probe["value"] = json.loads(json.dumps(self.core["value"]))
        probe["value"]["blocks"] = [{"id": "x", "type": "paragraph", "content": [
            {"type": "text", "value": "safe", "marks": [{"type": "link", "href": "https://example.test/a?x=1&y=2"}]},
            {"type": "text", "value": "unsafe", "marks": [{"type": "link", "href": "javascript:alert(1)"}]},
        ]}]
        rendered = public_adapter(probe).decode()
        self.assertIn('<a href="https://example.test/a?x=1&amp;y=2">safe</a>', rendered)
        self.assertNotIn("javascript:", rendered)

    def test_headerless_table_does_not_invent_headers(self) -> None:
        probe = dict(self.core)
        probe["value"] = json.loads(json.dumps(self.core["value"]))
        probe["value"]["blocks"] = [{"id": "t", "type": "table", "rows": [[[{"type": "text", "value": "body"}]]]}]
        self.assertNotIn("<thead>", public_adapter(probe).decode())

    def test_tui80_has_no_overwidth_lines(self) -> None:
        self.assertLessEqual(max(map(len, tui_adapter(self.core).decode().splitlines())), 80)

    def test_email_declares_truthful_mime(self) -> None:
        message = email_adapter(self.core)
        self.assertIn(b"MIME-Version: 1.0\r\n", message)
        self.assertIn(b"Content-Type: multipart/alternative", message)
        self.assertIn(b"Content-Type: text/html; charset=UTF-8", message)

    def test_studio_receipt_does_not_proxy_pass(self) -> None:
        payload = json.loads(studio_adapter(self.core))
        self.assertTrue(payload["real_reader_status"].startswith("BLOCKED_"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
