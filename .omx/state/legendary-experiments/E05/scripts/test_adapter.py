#!/usr/bin/env python3
"""Focused regression tests for the E05 compatibility envelope."""

from __future__ import annotations

import unittest

from adapter import build_envelope, remove_envelope, semantic_hash


class PreservationEnvelopeTests(unittest.TestCase):
    def test_markdown_source_is_preserved_and_rendered(self) -> None:
        source = {"_id": "md", "body": "# Heading\n\nAuthored copy"}
        envelope = build_envelope(source, fixture_id="md", unit_type="paper", cohort="markdown_only_failure")
        self.assertEqual(source, envelope["source"])
        self.assertEqual("body", envelope["provenance"]["authoritative_source_path"])
        self.assertIn("Authored copy", envelope["reader_views"]["CLI/API"]["output"])

    def test_html_source_is_preserved_and_falls_back(self) -> None:
        source = {"_id": "html", "body_html": "<h1>Title</h1><p>Copy</p>"}
        envelope = build_envelope(source, fixture_id="html", unit_type="paper", cohort="html_only_control")
        self.assertEqual(source, envelope["source"])
        self.assertEqual("Title\nCopy", envelope["reader_contract"]["text"])

    def test_malformed_authoritative_source_is_not_masked(self) -> None:
        source = {"_id": "bad", "blocks": [{"type": 7, "children": "not-a-list"}], "description": "tempting fallback"}
        envelope = build_envelope(source, fixture_id="bad", unit_type="paper", cohort="malformed")
        self.assertEqual("supported_error", envelope["reader_contract"]["status"])
        self.assertEqual("malformed_authoritative_source", envelope["reader_contract"]["error"])
        self.assertIn("description", envelope["provenance"]["conflicts_reported_not_selected"])

    def test_task_recommendation_is_advisory(self) -> None:
        source = {"_id": "task", "title": "Do the work", "lifecycle_status": "open"}
        envelope = build_envelope(source, fixture_id="task", unit_type="task", cohort="executable")
        self.assertEqual("advisory_only", envelope["annotation"]["authority"])
        self.assertEqual("open", envelope["source"]["lifecycle_status"])
        self.assertNotIn("recommended_class", envelope["source"])

    def test_second_run_and_rollback_are_exact(self) -> None:
        source = {"_id": "x", "blocks": [{"type": "paragraph", "text": "hello"}]}
        first = build_envelope(source, fixture_id="x", unit_type="paper", cohort="control")
        second = build_envelope(first, fixture_id="x", unit_type="paper", cohort="control")
        self.assertEqual(semantic_hash(first), semantic_hash(second))
        self.assertEqual(source, remove_envelope(first))

    def test_long_token_is_wrapped_without_loss(self) -> None:
        token = "x" * 4096
        source = {"_id": "token", "body": token}
        envelope = build_envelope(source, fixture_id="token", unit_type="adversarial", cohort="long_unbroken_tokens")
        tui = envelope["reader_views"]["TUI"]["output"]
        self.assertEqual(token, tui.replace("\n", ""))
        self.assertLessEqual(max(map(len, tui.splitlines())), 20)


if __name__ == "__main__":
    unittest.main(verbosity=2)
