#!/usr/bin/env python3

import unittest

from paper_epic_repair import (
    SITE_SPAWNER_ID,
    SITE_SPAWNER_NOTE_LISTS,
    SITE_SPAWNER_NOTE_TABLES,
    SITE_SPAWNER_STEP_LISTS,
    SPACING_DOCTRINE_ID,
    _list_as_notes,
    _list_as_steps,
    _table_as_notes,
    curate_site_spawner_wave10,
    repair_canonical_epic,
    repair_spacing_doctrine,
)
from paper_quality import audit_papers


def text(value):
    return [{"type": "text", "value": value}]


class PaperEpicRepairTest(unittest.TestCase):
    def test_list_reframes_are_lossless_and_semantic(self):
        block = {
            "id": "findings",
            "type": "list",
            "items": [text("First claim. Its evidence remains exact.")],
        }
        note = _list_as_notes(block, "finding")
        step = _list_as_steps(block)

        self.assertEqual(note["type"], "notes")
        self.assertEqual(note["items"][0]["lead"], "First claim.")
        self.assertEqual(note["items"][0]["text"], "Its evidence remains exact.")
        self.assertEqual(step["type"], "steps")
        self.assertEqual(step["steps"][0]["title"], "First claim.")
        self.assertEqual(
            step["steps"][0]["blocks"][0]["content"][0]["value"],
            "Its evidence remains exact.",
        )

    def test_table_reframes_preserve_each_cell(self):
        block = {
            "id": "questions",
            "type": "table",
            "head": [text("key"), text("question"), text("why")],
            "rows": [[text("alpha"), text("What?"), text("It decides.")]],
        }

        note = _table_as_notes(block, "headed")

        self.assertEqual(
            note["items"],
            [{"label": "alpha", "lead": "What?", "text": "It decides."}],
        )

    def test_profile_is_revision_fenced_and_fails_on_frozen_shape_drift(self):
        blocks = [
            {
                "id": "h1",
                "type": "heading",
                "level": 1,
                "text": "Wave 10",
            }
        ]
        blocks.extend(
            {"id": "gap-{}".format(index), "type": "paragraph", "content": []}
            for index in range(127)
        )
        blocks.extend(
            {
                "id": block_id,
                "type": "list",
                "items": [text("Claim. Evidence.")],
            }
            for block_id in SITE_SPAWNER_NOTE_LISTS
        )
        blocks.extend(
            {
                "id": block_id,
                "type": "list",
                "items": [text("First. Then.")],
            }
            for block_id in SITE_SPAWNER_STEP_LISTS
        )
        for block_id, mode in SITE_SPAWNER_NOTE_TABLES.items():
            if mode == "two-column":
                rows = [[text("Finding"), text("Consequence")]]
            elif mode == "first-row-header":
                rows = [
                    [text("key"), text("verdict"), text("proof")],
                    [text("alpha"), text("Holds"), text("Run")],
                ]
            else:
                rows = [[text("alpha"), text("Question"), text("Why")]]
            blocks.append({"id": block_id, "type": "table", "rows": rows})
        document = {
            "_id": SITE_SPAWNER_ID,
            "_rev": "frozen-rev",
            "blocks": blocks,
        }

        mutation = curate_site_spawner_wave10(document)
        patch = mutation["mutations"][0]["patch"]
        repaired = patch["set"]["blocks"]

        self.assertEqual(patch["ifRevisionID"], "frozen-rev")
        self.assertFalse(
            any(
                block.get("type") == "paragraph"
                and block.get("content") == []
                for block in repaired
            )
        )
        self.assertEqual(
            [block["type"] for block in repaired[:4]],
            ["heading", "ingress", "byline", "stats"],
        )
        self.assertEqual(
            mutation["mutations"][1],
            {"publish": {"id": SITE_SPAWNER_ID, "type": "paper"}},
        )

        document["blocks"].pop()
        with self.assertRaisesRegex(ValueError, "targets missing"):
            curate_site_spawner_wave10(document)

    def test_spacing_doctrine_reverses_the_spacer_law_under_a_revision_fence(self):
        document = {
            "_id": SPACING_DOCTRINE_ID,
            "_rev": "doctrine-rev",
            "blocks": [{"id": "old", "type": "paragraph", "content": []}],
        }

        mutation = repair_spacing_doctrine(document)
        patch = mutation["mutations"][0]["patch"]
        blocks = patch["set"]["blocks"]
        rendered = str(patch["set"])

        self.assertEqual(patch["ifRevisionID"], "doctrine-rev")
        self.assertEqual(
            [block["type"] for block in blocks[:5]],
            ["eyebrow", "heading", "ingress", "byline", "stats"],
        )
        self.assertFalse(any(_block.get("content") == [] for _block in blocks))
        self.assertIn("Readers own vertical rhythm", rendered)
        self.assertIn("no published visual content", rendered)

    def test_generic_canonical_repair_preserves_text_and_fixes_composition(self):
        document = {
            "_id": "wave-under-repair",
            "_rev": "source-rev",
            "title": "wave-under-repair",
            "description": "This wave closes the unverified release path with executed evidence.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {"id": "gap", "type": "paragraph", "content": []},
                {
                    "id": "ground",
                    "type": "heading",
                    "level": "1",
                    "text": "Wave under repair",
                },
                {
                    "id": "dense",
                    "type": "list",
                    "items": [
                        text(
                            "This long finding preserves every factual word while the "
                            "repair changes its visual treatment into an annotated note "
                            "that a reader can scan without mistaking a paragraph for a "
                            "small bullet in an otherwise dense evidence section today, "
                            "while retaining its source claim, consequence, provenance, "
                            "and explicit endgame without abbreviation or invention."
                        )
                    ],
                },
                {
                    "id": "table",
                    "type": "table",
                    "head": [text("result")],
                    "rows": [[text("row {}".format(i))] for i in range(13)],
                },
            ],
        }

        mutation = repair_canonical_epic(document)
        patch = mutation["mutations"][0]["patch"]
        repaired = patch["set"]["blocks"]

        self.assertEqual(patch["ifRevisionID"], "source-rev")
        self.assertEqual(patch["set"]["title"], "Wave under repair")
        self.assertEqual(repaired[0]["type"], "heading")
        self.assertEqual(repaired[0]["level"], 1)
        self.assertEqual(
            [block["type"] for block in repaired[:3]],
            ["heading", "ingress", "stats"],
        )
        self.assertFalse(
            any(
                block.get("type") == "paragraph"
                and block.get("content") == []
                for block in repaired
            )
        )
        self.assertEqual(
            [block["type"] for block in repaired if block.get("id") == "dense"],
            ["notes"],
        )
        split_tables = [
            block for block in repaired if block.get("type") == "table"
        ]
        self.assertEqual([len(block["rows"]) for block in split_tables], [12, 1])
        self.assertIn("preserves every factual word", str(repaired))

    def test_generic_repair_promotes_headers_and_moves_step_prose_into_bodies(self):
        document = {
            "_id": "semantic-repair",
            "_rev": "source-rev",
            "title": "Semantic repair",
            "description": "This wave makes its evidence legible in every reader.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {"type": "heading", "level": 1, "text": "Semantic repair"},
                {
                    "type": "steps",
                    "steps": [
                        {
                            "title": (
                                "Run the complete proof before merge and preserve the "
                                "exact output because the next reviewer needs the "
                                "failure mode and the successful rerun"
                            ),
                            "blocks": [],
                        }
                    ],
                },
                {
                    "type": "table",
                    "rows": [
                        [text("claim"), text("proof")],
                        [text("the lane works"), text("executed output")],
                    ],
                },
            ],
        }

        mutation = repair_canonical_epic(document)
        repaired = mutation["mutations"][0]["patch"]["set"]["blocks"]
        steps = next(block for block in repaired if block.get("type") == "steps")
        table = next(block for block in repaired if block.get("type") == "table")

        self.assertLessEqual(len(steps["steps"][0]["title"].split()), 16)
        self.assertEqual(len(steps["steps"][0]["blocks"]), 1)
        self.assertEqual(table["head"], [text("claim"), text("proof")])
        self.assertEqual(table["rows"], [[text("the lane works"), text("executed output")]])

    def test_generic_repair_collapses_evidence_wall_without_losing_source_text(self):
        sections = []
        for index in range(18):
            sections.extend(
                [
                    {
                        "type": "heading",
                        "level": 2,
                        "text": "Evidence {}".format(index),
                    },
                    {
                        "type": "paragraph",
                        "content": text(
                            "section-{} ".format(index) + ("proof " * 320)
                        ),
                    },
                ]
            )
        document = {
            "_id": "appendix-repair",
            "_rev": "source-rev",
            "title": "Appendix repair",
            "description": "This wave keeps the argument readable without losing proof.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {"type": "heading", "level": 1, "text": "Appendix repair"},
                *sections,
            ],
        }

        mutation = repair_canonical_epic(document)
        repaired = mutation["mutations"][0]["patch"]["set"]["blocks"]
        appendices = [
            block
            for block in repaired
            if block.get("type") == "expandable"
            and str(block.get("id", "")).startswith("epb-evidence-appendix-")
        ]

        self.assertGreaterEqual(len(appendices), 1)
        self.assertLessEqual(len(appendices), 4)
        self.assertIn("section-17", str(repaired))

    def test_generic_repair_hides_prose_heavy_detail_from_the_first_pass(self):
        document = {
            "_id": "dense-detail-repair",
            "_rev": "source-rev",
            "title": "Dense detail repair",
            "description": "This wave keeps the decision visible and the proof available.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {"type": "heading", "level": 1, "text": "Dense detail repair"},
                {
                    "type": "paragraph",
                    "content": text("evidence " * 180),
                },
            ],
        }

        mutation = repair_canonical_epic(document)
        repaired = mutation["mutations"][0]["patch"]["set"]["blocks"]
        candidate = {**document, "blocks": repaired}
        report = audit_papers([candidate])["papers"][0]

        self.assertTrue(report["pass"])
        self.assertEqual(report["warnings"], [])
        self.assertTrue(
            any(block.get("type") == "expandable" for block in repaired)
        )

    def test_generic_repair_keeps_four_relevant_tags_and_the_main_tag(self):
        document = {
            "_id": "tag-repair",
            "_rev": "source-rev",
            "title": "Tag repair",
            "description": "This wave keeps a compact, relevant Paper identity.",
            "main_tag": "primary",
            "tags": [
                {"tag": "primary", "strength": 95},
                {"tag": "secondary", "strength": 80},
                {"tag": "tertiary", "strength": 70},
                {"tag": "discarded", "strength": 20},
                {"tag": "epic-cycle-wave-paper", "strength": 90},
            ],
            "blocks": [
                {"type": "heading", "level": 1, "text": "Tag repair"},
                {"type": "paragraph", "content": text("The argument.")},
            ],
        }

        mutation = repair_canonical_epic(document)
        patch_set = mutation["mutations"][0]["patch"]["set"]
        tags = [tag["tag"] for tag in patch_set["tags"]]

        self.assertEqual(
            tags,
            ["epic-cycle-wave-paper", "primary", "secondary", "tertiary"],
        )
        self.assertNotIn("main_tag", patch_set)

    def test_source_truth_wave_tags_are_distinct_and_main_tag_stays_relevant(self):
        document = {
            "_id": "source-of-truth-grip-wave-7-2026-07-21",
            "_rev": "source-rev",
            "title": "Source truth wave 7",
            "description": "This wave proves the command ledger.",
            "main_tag": "wave-strategy",
            "tags": [
                {"tag": "wave-strategy", "strength": 95},
                {"tag": "epic-cycle-wave-paper", "strength": 80},
                {"tag": "ledger", "strength": 70},
                {"tag": "measurement", "strength": 60},
                {"tag": "cli", "strength": 45},
            ],
            "blocks": [
                {"type": "heading", "level": 1, "text": "Source truth wave 7"},
                {"type": "paragraph", "content": text("The argument.")},
            ],
        }

        mutation = repair_canonical_epic(document)
        patch_set = mutation["mutations"][0]["patch"]["set"]

        self.assertEqual(
            [tag["tag"] for tag in patch_set["tags"]],
            ["ledger", "measurement", "cli", "epic-cycle-wave-paper"],
        )
        self.assertEqual(patch_set["main_tag"], "ledger")

    def test_generic_repair_leads_with_h1_and_dedupes_editorial_callout_label(self):
        editorial_text = (
            "Editorial status (superseded): preserve this Paper as historical "
            "evidence, not current authority."
        )
        document = {
            "_id": "editorial-opening-repair",
            "_rev": "source-rev",
            "title": "Editorial opening repair",
            "description": "This wave keeps editorial context without burying its title.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {
                    "type": "callout",
                    "title": "Editorial status",
                    "content": text(editorial_text),
                },
                {
                    "type": "heading",
                    "level": 2,
                    "text": "Historical evidence",
                },
                {"type": "paragraph", "content": text("The argument.")},
            ],
        }

        mutation = repair_canonical_epic(document)
        repaired = mutation["mutations"][0]["patch"]["set"]["blocks"]
        editorial_callout = next(
            block
            for block in repaired
            if block.get("type") == "callout"
            and editorial_text in str(block.get("content"))
        )

        self.assertEqual(repaired[0]["type"], "heading")
        self.assertEqual(repaired[0]["level"], 1)
        self.assertNotIn("title", editorial_callout)


if __name__ == "__main__":
    unittest.main()
