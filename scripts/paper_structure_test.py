#!/usr/bin/env python3

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from paper_structure import audit_documents, canonicalize_blocks, write_repair_plan


def text(value):
    return [{"type": "text", "value": value}]


class PaperStructureAuditTest(unittest.TestCase):
    def test_site_spawner_dialect_is_fully_path_addressed(self):
        document = {
            "_id": "site-spawner-wave-10",
            "_rev": "rev-1",
            "blocks": [
                {"type": "list", "items": [{"content": text("visible intent")}]},
                {
                    "type": "table",
                    "rows": [
                        {
                            "header": True,
                            "cells": [{"content": text("heading")}],
                        },
                        {"cells": [{"content": text("body")}]},
                    ],
                },
                {"type": "callout", "text": "stranded"},
            ],
        }

        report = audit_documents([document])

        self.assertEqual(report["papers_scanned"], 1)
        self.assertEqual(report["papers_affected"], 1)
        self.assertEqual(report["violations"], 7)
        self.assertEqual(report["safe_repair_violations"], 7)
        self.assertEqual(
            report["violation_counts"],
            {
                "callout_text_stranded": 1,
                "list_item_object_wrapper": 1,
                "table_cell_object_wrapper": 2,
                "table_row_header_marker": 1,
                "table_row_object_wrapper": 2,
            },
        )

    def test_canonical_shapes_are_clean(self):
        document = {
            "_id": "clean",
            "_rev": "rev-1",
            "blocks": [
                {"type": "list", "items": [text("item")]},
                {
                    "type": "table",
                    "head": [text("heading")],
                    "rows": [[text("body")]],
                },
                {"type": "callout", "content": text("body")},
            ],
        }

        report = audit_documents([document])
        self.assertEqual(report["violations"], 0)
        self.assertEqual(report["papers_affected"], 0)

    def test_ambiguous_wrappers_are_quarantined(self):
        document = {
            "_id": "ambiguous",
            "_rev": "rev-1",
            "blocks": [
                {
                    "type": "list",
                    "items": [{"content": text("item"), "url": "keep-me"}],
                },
                {
                    "type": "table",
                    "rows": [{"cells": [{"content": text("cell"), "span": 2}]}],
                },
            ],
        }

        report = audit_documents([document])
        self.assertEqual(report["violations"], 3)
        self.assertEqual(report["safe_repair_violations"], 1)
        self.assertEqual(report["quarantined_violations"], 2)

    def test_html_only_paper_is_not_a_structural_violation(self):
        report = audit_documents(
            [{"_id": "html-only", "_rev": "rev-1", "body_html": "<p>Valid</p>"}]
        )
        self.assertEqual(report["violations"], 0)

    def test_canonicalizer_is_lossless_and_idempotent_for_known_dialects(self):
        blocks = [
            {
                "type": "table",
                "columns": [
                    {"key": "k", "label": "Key"},
                    {"key": "why", "label": "Why"},
                ],
                "rows": [{"why": "Because", "k": "A"}],
            },
            {
                "type": "table",
                "rows": [
                    {
                        "cells": [
                            {
                                "header": True,
                                "content": [
                                    {"type": "paragraph", "content": text("Head")}
                                ],
                            }
                        ]
                    },
                    {"cells": [{"content": text("Body")}]},
                ],
            },
            {
                "type": "list",
                "items": [
                    {"content": text("flatten")},
                    {"id": "keep", "content": text("preserve wrapper")},
                ],
            },
        ]

        normalized = canonicalize_blocks(blocks)
        self.assertEqual(normalized[0]["head"], [text("Key"), text("Why")])
        self.assertEqual(normalized[0]["rows"], [[text("A"), text("Because")]])
        self.assertEqual(normalized[1]["head"], [text("Head")])
        self.assertEqual(normalized[1]["rows"], [[text("Body")]])
        self.assertEqual(normalized[2]["items"][0], text("flatten"))
        self.assertEqual(normalized[2]["items"][1], blocks[2]["items"][1])
        self.assertEqual(canonicalize_blocks(normalized), normalized)

    def test_record_table_with_structured_values_is_quarantined(self):
        blocks = [
            {
                "type": "table",
                "columns": [{"key": "proof", "label": "Proof"}],
                "rows": [{"proof": text("do not stringify this structure")}],
            }
        ]
        document = {"_id": "structured-record", "_rev": "rev-1", "blocks": blocks}

        report = audit_documents([document])

        self.assertEqual(report["violations"], 1)
        self.assertEqual(report["safe_repair_violations"], 0)
        self.assertEqual(report["quarantined_violations"], 1)
        self.assertEqual(canonicalize_blocks(blocks), blocks)

    def test_contentless_metadata_wrappers_are_not_mistaken_for_supported_ids(self):
        document = {
            "_id": "contentless",
            "_rev": "rev-1",
            "blocks": [
                {"type": "list", "items": [{"id": "item-without-content"}]},
                {"type": "table", "rows": [[{"text": "not inline content"}]]},
            ],
        }

        report = audit_documents([document])

        self.assertEqual(report["violations"], 2)
        self.assertEqual(report["safe_repair_violations"], 0)
        self.assertEqual(report["quarantined_violations"], 2)
        self.assertEqual(
            report["violation_counts"],
            {
                "list_item_object_wrapper": 1,
                "table_cell_unrenderable": 1,
            },
        )

    def test_scalar_list_items_have_a_deterministic_repair(self):
        blocks = [{"type": "list", "items": ["one", 2, None]}]
        document = {"_id": "scalars", "_rev": "rev-1", "blocks": blocks}

        report = audit_documents([document])
        normalized = canonicalize_blocks(blocks)

        self.assertEqual(report["violations"], 3)
        self.assertEqual(report["safe_repair_violations"], 3)
        self.assertEqual(
            normalized[0]["items"],
            [text("one"), text("2"), []],
        )

    def test_repair_plan_has_exact_backups_and_revision_fences(self):
        document = {
            "_id": "paper-1",
            "_rev": "rev-1",
            "blocks": [{"type": "callout", "text": "Visible"}],
        }
        with TemporaryDirectory() as temp:
            plan_dir = Path(temp) / "plan"
            manifest = write_repair_plan([document], plan_dir)
            payload = __import__("json").loads(
                (plan_dir / "mutations" / "repair-001.json").read_text()
            )
            patch = payload["mutations"][0]["patch"]
            self.assertEqual(manifest["papers_changed"], 1)
            self.assertEqual(patch["ifRevisionID"], "rev-1")
            self.assertEqual(patch["set"]["blocks"][0]["content"], text("Visible"))
            self.assertEqual(
                payload["mutations"][1]["publish"],
                {"id": "paper-1", "type": "paper"},
            )
            self.assertTrue((plan_dir / "backups" / "paper-1.json").exists())


if __name__ == "__main__":
    unittest.main()
