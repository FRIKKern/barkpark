#!/usr/bin/env python3

import unittest

from paper_quality import audit_papers


def text(value):
    return [{"type": "text", "value": value}]


def reference_shape():
    return {
        "_id": "reference",
        "_rev": "rev-1",
        "style": "article",
        "tags": [{"tag": "epic-cycle-wave-paper"}],
        "blocks": [
            {"type": "eyebrow", "text": "BARKPARK PAPERS · ESSAY"},
            {"type": "heading", "level": 1, "text": "A clear thesis"},
            {"type": "ingress", "content": text("Purpose, stakes, and the argument.")},
            {"type": "byline", "items": ["proof", "scope"]},
            {
                "type": "stats",
                "items": [{"value": "17", "label": "canonical papers"}],
            },
            {"type": "heading", "level": 2, "text": "First decision"},
            {"type": "paragraph", "content": text("The evidence and its meaning.")},
        ],
    }


class PaperQualityAuditTest(unittest.TestCase):
    def test_reference_shape_scores_100_without_rewarding_extra_ornament(self):
        report = audit_papers([reference_shape()])

        self.assertTrue(report["pass"])
        self.assertEqual(report["papers"][0]["score"], 100)
        self.assertEqual(report["papers"][0]["hard_failures"], [])

    def test_hollow_and_micro_papers_fail(self):
        hollow = {
            "_id": "hollow",
            "_rev": "rev-h",
            "style": "article",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [],
        }
        micro = {
            "_id": "micro",
            "_rev": "rev-m",
            "style": "article",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [{"type": "heading", "level": 1, "text": "Only a title"}],
        }

        report = audit_papers([hollow, micro])
        failures = {
            paper["paper_id"]: set(paper["hard_failures"])
            for paper in report["papers"]
        }

        self.assertIn("hollow", failures["hollow"])
        self.assertIn("micro_only", failures["micro"])
        self.assertFalse(report["pass"])

    def test_empty_spacers_and_missing_editorial_opening_fail(self):
        paper = reference_shape()
        paper["_id"] = "gap"
        paper["blocks"].insert(2, {"type": "paragraph", "content": []})
        paper["blocks"] = [
            block for block in paper["blocks"] if block.get("type") != "ingress"
        ]

        result = audit_papers([paper])["papers"][0]

        self.assertIn("empty_paragraph_spacer", result["hard_failures"])
        self.assertIn("opening_missing_ingress", result["hard_failures"])

    def test_reader_evidence_is_revision_pinned_and_fail_closed_when_required(self):
        paper = reference_shape()
        evidence = {
            "reference": {
                "revision": "rev-1",
                "readers": {
                    "public": "pass",
                    "studio": "pass",
                    "tui80": "pass",
                    "email": "fail",
                    "cli_api": "pass",
                },
            }
        }

        failed = audit_papers(
            [paper], reader_evidence=evidence, require_reader_evidence=True
        )["papers"][0]
        self.assertIn("reader_email_failed", failed["hard_failures"])

        evidence["reference"]["readers"]["email"] = "pass"
        passed = audit_papers(
            [paper], reader_evidence=evidence, require_reader_evidence=True
        )["papers"][0]
        self.assertEqual(passed["hard_failures"], [])

        evidence["reference"]["revision"] = "other"
        stale = audit_papers(
            [paper], reader_evidence=evidence, require_reader_evidence=True
        )["papers"][0]
        self.assertIn("reader_evidence_revision_mismatch", stale["hard_failures"])

    def test_reader_content_proof_requires_matching_semantic_hashes(self):
        paper = reference_shape()
        semantic_hash = "a" * 64
        evidence = {
            "reference": {
                "revision": "rev-1",
                "semantic_text_sha256": semantic_hash,
                "readers": {
                    reader: {
                        "status": "pass",
                        "semantic_text_sha256": semantic_hash,
                    }
                    for reader in ("public", "studio", "tui80", "email", "cli_api")
                },
            }
        }

        passed = audit_papers(
            [paper],
            reader_evidence=evidence,
            require_reader_evidence=True,
            require_reader_content_proof=True,
        )["papers"][0]
        self.assertEqual(passed["hard_failures"], [])

        evidence["reference"]["readers"]["tui80"] = "pass"
        missing = audit_papers(
            [paper],
            reader_evidence=evidence,
            require_reader_evidence=True,
            require_reader_content_proof=True,
        )["papers"][0]
        self.assertIn(
            "reader_tui80_content_proof_missing", missing["hard_failures"]
        )

        evidence["reference"]["readers"]["tui80"] = {
            "status": "pass",
            "semantic_text_sha256": "b" * 64,
        }
        mismatch = audit_papers(
            [paper],
            reader_evidence=evidence,
            require_reader_evidence=True,
            require_reader_content_proof=True,
        )["papers"][0]
        self.assertIn(
            "reader_tui80_content_proof_mismatch", mismatch["hard_failures"]
        )

    def test_duplicate_ids_and_appendix_numbering_fail(self):
        paper = reference_shape()
        paper["blocks"].extend(
            [
                {
                    "id": "epb-evidence-appendix-1",
                    "type": "expandable",
                    "summary": "Evidence appendix 1 — first",
                    "children": [
                        {"id": "proof", "type": "paragraph", "content": text("one")}
                    ],
                },
                {
                    "id": "epb-evidence-appendix-1",
                    "type": "expandable",
                    "summary": "Evidence appendix 1 — second",
                    "children": [
                        {"id": "proof", "type": "paragraph", "content": text("two")}
                    ],
                },
            ]
        )

        result = audit_papers([paper])["papers"][0]

        self.assertIn("duplicate_block_id", result["hard_failures"])
        self.assertIn("evidence_appendix_numbering", result["hard_failures"])

    def test_dense_lists_and_tables_warn_but_do_not_fake_a_hard_semantic_verdict(self):
        paper = reference_shape()
        paper["blocks"].extend(
            [
                {
                    "type": "list",
                    "items": [text("word " * 45)],
                },
                {
                    "type": "table",
                    "head": [text("row")],
                    "rows": [[text(str(i))] for i in range(13)],
                },
            ]
        )

        result = audit_papers([paper])["papers"][0]

        self.assertEqual(result["hard_failures"], [])
        self.assertEqual(
            set(result["warnings"]),
            {"paragraph_sized_list_item", "oversized_table"},
        )
        self.assertLess(result["score"], 100)

    def test_reference_style_steps_have_short_titles_and_real_bodies(self):
        paper = reference_shape()
        paper["blocks"].append(
            {
                "type": "steps",
                "steps": [
                    {
                        "title": "State the governing constraint",
                        "blocks": [
                            {
                                "type": "paragraph",
                                "content": text(
                                    "Explain why it matters and what changes next."
                                ),
                            }
                        ],
                    }
                ],
            }
        )

        result = audit_papers([paper])["papers"][0]

        self.assertEqual(result["hard_failures"], [])
        self.assertEqual(result["metrics"]["empty_step_bodies"], 0)

    def test_title_only_steps_and_headerless_tables_fail_semantic_composition(self):
        paper = reference_shape()
        paper["blocks"].extend(
            [
                {
                    "type": "steps",
                    "steps": [
                        {
                            "title": (
                                "This entire paragraph was stuffed into a title even "
                                "though a step needs a concise action and a real body "
                                "that explains its purpose and evidence"
                            ),
                            "blocks": [],
                        }
                    ],
                },
                {
                    "type": "table",
                    "rows": [[text("column"), text("meaning")]],
                },
            ]
        )

        result = audit_papers([paper])["papers"][0]

        self.assertIn("empty_step_body", result["hard_failures"])
        self.assertIn("overloaded_step_title", result["hard_failures"])
        self.assertIn("table_missing_header", result["hard_failures"])

    def test_semantic_failures_are_found_inside_step_bodies(self):
        paper = reference_shape()
        paper["blocks"].append(
            {
                "type": "steps",
                "steps": [
                    {
                        "title": "Inspect the nested evidence",
                        "blocks": [
                            {"type": "paragraph", "content": []},
                            {
                                "type": "table",
                                "rows": [[text("claim"), text("proof")]],
                            },
                        ],
                    }
                ],
            }
        )

        result = audit_papers([paper])["papers"][0]

        self.assertIn("empty_paragraph_spacer", result["hard_failures"])
        self.assertIn("table_missing_header", result["hard_failures"])

    def test_collapsed_appendix_preserves_evidence_without_bloating_first_pass(self):
        paper = reference_shape()
        paper["blocks"].append(
            {
                "type": "expandable",
                "summary": "Full evidence appendix",
                "children": [
                    {
                        "type": "paragraph",
                        "content": text("evidence " * 5_100),
                    }
                ],
            }
        )

        result = audit_papers([paper])["papers"][0]

        self.assertNotIn("primary_reading_load_exceeded", result["hard_failures"])
        self.assertGreater(result["metrics"]["visible_words"], 5_000)
        self.assertLess(result["metrics"]["primary_visible_words"], 5_000)

    def test_unstructured_primary_reading_load_and_heading_wall_fail(self):
        paper = reference_shape()
        paper["blocks"].extend(
            {
                "type": "heading",
                "level": 2,
                "text": "Evidence section {}".format(index),
            }
            for index in range(16)
        )
        paper["blocks"].append(
            {
                "type": "paragraph",
                "content": text("primary " * 5_100),
            }
        )

        result = audit_papers([paper])["papers"][0]

        self.assertIn("primary_reading_load_exceeded", result["hard_failures"])
        self.assertIn("top_level_heading_overload", result["hard_failures"])


if __name__ == "__main__":
    unittest.main()
