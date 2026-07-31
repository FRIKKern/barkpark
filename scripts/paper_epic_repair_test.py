#!/usr/bin/env python3

import copy
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
    repair_strategic_paper,
)
from paper_quality import audit_papers


def text(value):
    return [{"type": "text", "value": value}]


class PaperEpicRepairTest(unittest.TestCase):
    def test_strategic_repair_preserves_taxonomy_and_is_idempotent(self):
        tags = [
            {
                "tag": "jarl-website",
                "strength": 90,
                "rationale": "The record lands on jarl.no",
            },
            {
                "tag": "epic-wave-strategy",
                "strength": 75,
                "rationale": "The charter guides an epic",
            },
        ]
        document = {
            "_id": "strategic-charter",
            "_rev": "source-rev",
            "title": "strategic-charter",
            "description": "A decision charter whose authored claims must remain exact.",
            "main_tag": "jarl-website",
            "tags": tags,
            "blocks": [
                {"id": "eyebrow", "type": "eyebrow", "text": "LIVE CHARTER"},
                {
                    "id": "title",
                    "type": "heading",
                    "level": 1,
                    "text": "The strategic charter",
                },
                {
                    "id": "opening",
                    "type": "ingress",
                    "content": text("The existing authored opening remains exact."),
                },
                {"id": "gap-a", "type": "paragraph", "content": []},
                {"id": "gap-b", "type": "paragraph", "content": []},
                {
                    "id": "decision",
                    "type": "callout",
                    "title": "Decision",
                    "content": text("Keep the public record specific and useful."),
                },
                {
                    "id": "why",
                    "type": "heading",
                    "level": 2,
                    "text": "Why this decision exists",
                },
                {
                    "id": "blocks",
                    "type": "heading",
                    "level": 2,
                    "text": "What it blocks",
                },
                {
                    "id": "endgame",
                    "type": "heading",
                    "level": 2,
                    "text": "Endgame",
                },
            ],
        }

        mutation = repair_strategic_paper(document)
        patch = mutation["mutations"][0]["patch"]
        repaired = patch["set"]["blocks"]

        self.assertEqual(patch["ifRevisionID"], "source-rev")
        self.assertNotIn("tags", patch["set"])
        self.assertNotIn("main_tag", patch["set"])
        self.assertEqual(
            [block["type"] for block in repaired[:4]],
            ["eyebrow", "heading", "ingress", "byline"],
        )
        self.assertEqual(
            repaired[3]["items"],
            ["Why this decision exists", "What it blocks", "Endgame"],
        )
        self.assertNotIn("source words", str(repaired[:8]))
        self.assertFalse(
            any(
                block.get("type") == "paragraph"
                and block.get("content") == []
                for block in repaired
            )
        )
        self.assertIn("The existing authored opening remains exact.", str(repaired))
        self.assertIn("Keep the public record specific and useful.", str(repaired))

        second_document = {
            **document,
            "_rev": "second-rev",
            "title": patch["set"].get("title", document["title"]),
            "blocks": repaired,
        }
        repaired_again = repair_strategic_paper(second_document)["mutations"][0][
            "patch"
        ]["set"]["blocks"]

        self.assertEqual(repaired_again, repaired)
        self.assertEqual(document["tags"], tags)
        self.assertEqual(document["main_tag"], "jarl-website")

    def test_strategic_repair_accepts_case_only_redundant_callout_title(self):
        document = {
            "_id": "case-only-callout-title",
            "_rev": "source-rev",
            "title": "Case-only callout title",
            "description": "This wave keeps the status claim once without inventing loss.",
            "blocks": [
                {
                    "id": "title",
                    "type": "heading",
                    "level": 1,
                    "text": "Case-only callout title",
                },
                {
                    "id": "status",
                    "type": "callout",
                    "title": "Wave status",
                    "content": text("WAVE STATUS: verification is in flight."),
                },
                {
                    "id": "direction",
                    "type": "heading",
                    "level": 2,
                    "text": "Direction",
                },
            ],
        }

        repaired = repair_strategic_paper(document)["mutations"][0]["patch"]["set"][
            "blocks"
        ]
        status = next(block for block in repaired if block.get("id") == "status")

        self.assertNotIn("title", status)
        self.assertIn("WAVE STATUS: verification is in flight.", str(status))

    def test_source_truth_wave_one_keeps_status_and_adds_current_authority_route(self):
        original_status = (
            "Editorial status (repair): foundational and candid, but the mixed "
            "branch and round state makes current authority difficult to extract."
        )
        document = {
            "_id": "source-of-truth-grip-wave-2026-07-20",
            "_rev": "source-rev",
            "title": "Source-of-Truth Grip — Wave 1",
            "description": "The first wave makes level-skips structurally impossible.",
            "blocks": [
                {
                    "id": "status",
                    "type": "callout",
                    "content": text(original_status),
                },
                {
                    "id": "title",
                    "type": "heading",
                    "level": 1,
                    "text": "Source-of-Truth Grip — Wave 1",
                },
                {
                    "id": "proof",
                    "type": "paragraph",
                    "content": text("The structural gate proves the level-skip contract."),
                },
            ],
        }

        repaired = repair_strategic_paper(document)["mutations"][0]["patch"]["set"][
            "blocks"
        ]
        status = next(block for block in repaired if block.get("id") == "status")
        status_text = str(status.get("content"))

        self.assertIn(original_status, status_text)
        self.assertIn("Wave 8 carries the current epic state", status_text)
        self.assertIn("level-skip contract", status_text)

        second_document = {**document, "_rev": "second-rev", "blocks": repaired}
        repaired_again = repair_strategic_paper(second_document)["mutations"][0][
            "patch"
        ]["set"]["blocks"]
        self.assertEqual(repaired_again, repaired)

    def test_source_truth_wave_two_gets_one_early_historical_authority_callout(self):
        document = {
            "_id": "source-of-truth-grip-wave-2-2026-07-20",
            "_rev": "source-rev",
            "title": "Source-of-Truth Grip — Wave 2",
            "description": "The gate aims the fleet and the ledger stores recipes.",
            "blocks": [
                {
                    "id": "title",
                    "type": "heading",
                    "level": 1,
                    "text": "Source-of-Truth Grip — Wave 2",
                },
                {
                    "id": "proof",
                    "type": "paragraph",
                    "content": text("The completed wave records the recipe-ledger decision."),
                },
            ],
        }

        repaired = repair_strategic_paper(document)["mutations"][0]["patch"]["set"][
            "blocks"
        ]
        authority = [
            block
            for block in repaired
            if block.get("id") == "epb-authority-boundary"
        ]

        self.assertEqual(len(authority), 1)
        self.assertLess(repaired.index(authority[0]), 4)
        self.assertIn("historical authority", str(authority[0].get("content")))
        self.assertIn("recipe-ledger decisions", str(authority[0].get("content")))
        self.assertIn("Wave 8 carries the current epic state", str(authority[0]))

        second_document = {**document, "_rev": "second-rev", "blocks": repaired}
        repaired_again = repair_strategic_paper(second_document)["mutations"][0][
            "patch"
        ]["set"]["blocks"]
        self.assertEqual(repaired_again, repaired)

    def test_wsc_wave_two_routes_current_readers_to_the_cockpit_wave(self):
        document = {
            "_id": "wsc-wave-2026-07-17",
            "_rev": "source-rev",
            "title": "",
            "description": "Wave 2 salvages the reviewed session-card implementation.",
            "blocks": [
                {
                    "id": "title",
                    "type": "heading",
                    "level": 1,
                    "text": "Wave Session Card — Wave 2: salvage the reviewed seam",
                },
                {
                    "id": "proof",
                    "type": "paragraph",
                    "content": text("The reviewed salvage tree remains the implementation spec."),
                },
            ],
        }

        mutation = repair_strategic_paper(document)
        patch_set = mutation["mutations"][0]["patch"]["set"]
        authority = next(
            block
            for block in patch_set["blocks"]
            if block.get("id") == "epb-authority-boundary"
        )

        self.assertEqual(
            patch_set["title"],
            "Wave Session Card — Wave 2: salvage the reviewed seam",
        )
        self.assertIn("historical authority", str(authority.get("content")))
        self.assertIn("Wave 4 carries the current cockpit", str(authority))

    def test_wsc_wave_four_keeps_cockpit_authority_but_routes_live_state(self):
        original_status = (
            "Editorial status (repair): run the cockpit work and preserve its "
            "reviewed decision record."
        )
        document = {
            "_id": "wsc-wave-2026-07-18",
            "_rev": "source-rev",
            "title": "Wave 4 — the cockpit wave",
            "description": "Wave 4 records the cockpit results and steering decision.",
            "blocks": [
                {
                    "id": "status",
                    "type": "callout",
                    "content": text(original_status),
                },
                {
                    "id": "title",
                    "type": "heading",
                    "level": 1,
                    "text": "Wave 4 — the cockpit wave",
                },
                {
                    "id": "proof",
                    "type": "paragraph",
                    "content": text("The reviewed D46 steering decision is recorded here."),
                },
            ],
        }

        mutation = repair_strategic_paper(document)
        patch_set = mutation["mutations"][0]["patch"]["set"]
        status = next(
            block for block in patch_set["blocks"] if block.get("id") == "status"
        )

        self.assertIn(original_status, str(status.get("content")))
        self.assertIn("cockpit results", str(status.get("content")))
        self.assertIn("Live task state remains authoritative", str(status.get("content")))

    def test_cloud_gui_round_twelve_uses_its_terminal_verdict_title_and_boundary(self):
        original_status = (
            "Editorial status (repair): keep as canonical authority, but prepend "
            "a corrected terminal summary."
        )
        document = {
            "_id": "cloud-gui-remake-wave-2026-07-21-r12",
            "_rev": "source-rev",
            "title": "Round 12: the 59 re-parents nobody has yet spent two minutes making",
            "description": "The terminal Cloud GUI seal wave.",
            "blocks": [
                {
                    "id": "status",
                    "type": "callout",
                    "content": text(original_status),
                },
                {
                    "id": "title",
                    "type": "heading",
                    "level": 1,
                    "text": "Cloud GUI Remake — round 12: the two mechanical acts, and the verdict",
                },
                {
                    "id": "proof",
                    "type": "paragraph",
                    "content": text("The terminal artifact records the code seal."),
                },
            ],
        }

        mutation = repair_strategic_paper(document)
        patch_set = mutation["mutations"][0]["patch"]["set"]
        status = next(
            block for block in patch_set["blocks"] if block.get("id") == "status"
        )

        self.assertEqual(
            patch_set["title"],
            "Cloud GUI Remake — round 12: the two mechanical acts, and the verdict",
        )
        self.assertIn(original_status, str(status.get("content")))
        self.assertIn("terminal code-seal authority", str(status.get("content")))
        self.assertIn("Cloud Console Hardening", str(status.get("content")))

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
            },
            {
                "id": "c-003",
                "type": "callout",
                "title": "The wish, in the owner's own order",
                "content": text(
                    "ONE — review the extractor and ability model. "
                    "TWO — walk the prebuilt deployment lane. "
                    "Plus: finish the admission gate and reconcile the ledger."
                ),
            },
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
            repaired[3]["items"],
            [
                {"value": "4", "label": "ability tiers re-derived"},
                {"value": "2", "label": "inherited premises disproved"},
                {"value": "1", "label": "first-party archive refusal class"},
            ],
        )
        wish = next(block for block in repaired if block.get("id") == "c-003")
        self.assertEqual(wish["type"], "steps")
        self.assertEqual(len(wish["steps"]), 3)
        self.assertIn(
            "ONE — review the extractor and ability model.",
            str(wish),
        )
        self.assertEqual(
            mutation["mutations"][1],
            {"publish": {"id": SITE_SPAWNER_ID, "type": "paper"}},
        )

        repeated_document = {
            **document,
            "_rev": "composed-rev",
            "blocks": repaired,
        }
        repeated = curate_site_spawner_wave10(repeated_document)["mutations"][0][
            "patch"
        ]["set"]["blocks"]
        self.assertEqual(repeated, repaired)

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
            ["heading", "ingress", "byline"],
        )
        self.assertEqual(
            repaired[2]["items"],
            ["Decision record", "Evidence and implications", "Next action"],
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

    def test_step_split_uses_a_clause_boundary_and_never_cuts_parentheses(self):
        original = (
            "THEN the wave-10 filed residue — #7863 + #7869 "
            "(do_rollback promising a rebuild it does not perform; the window "
            "remains false until the executed proof lands)."
        )
        document = {
            "_id": "semantic-step-boundary",
            "_rev": "source-rev",
            "title": "Semantic step boundary",
            "description": "This wave keeps action titles grammatical and evidence intact.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {"type": "heading", "level": 1, "text": "Semantic step boundary"},
                {
                    "type": "steps",
                    "steps": [{"title": original, "blocks": []}],
                },
            ],
        }

        repaired = repair_canonical_epic(document)["mutations"][0]["patch"]["set"][
            "blocks"
        ]
        step = next(block for block in repaired if block.get("type") == "steps")[
            "steps"
        ][0]

        self.assertEqual(step["title"], "THEN the wave-10 filed residue")
        self.assertEqual(
            step["blocks"][0]["content"][0]["value"],
            (
                "— #7863 + #7869 (do_rollback promising a rebuild it does not "
                "perform; the window remains false until the executed proof lands)."
            ),
        )
        self.assertNotIn("(", step["title"])

    def test_step_repair_heals_an_earlier_mid_phrase_title_split(self):
        document = {
            "_id": "semantic-step-healing",
            "_rev": "source-rev",
            "title": "Semantic step healing",
            "description": "This wave restores a grammatical action title from an older repair.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {"type": "heading", "level": 1, "text": "Semantic step healing"},
                {
                    "type": "steps",
                    "steps": [
                        {
                            "title": (
                                "MERGE ROUND 1 in the order above: #7866 then #7867 "
                                "(shared router"
                            ),
                            "blocks": [
                                {
                                    "type": "paragraph",
                                    "content": text(
                                        "file, different regions), #7869 and #7868."
                                    ),
                                }
                            ],
                        },
                        {
                            "title": (
                                "FILE THE FOUR ROWS FIRST, ssw10-reindex-token-prod-read "
                                "before anything else — it gates"
                            ),
                            "blocks": [
                                {
                                    "type": "paragraph",
                                    "content": text("the first production merge."),
                                }
                            ],
                        },
                    ],
                },
            ],
        }

        repaired = repair_canonical_epic(document)["mutations"][0]["patch"]["set"][
            "blocks"
        ]
        steps = next(block for block in repaired if block.get("type") == "steps")[
            "steps"
        ]

        self.assertEqual(steps[0]["title"], "MERGE ROUND 1 in the order above:")
        self.assertEqual(
            steps[0]["blocks"][0]["content"][0]["value"],
            "#7866 then #7867 (shared router file, different regions), #7869 and #7868.",
        )
        self.assertEqual(steps[1]["title"], "FILE THE FOUR ROWS FIRST,")
        self.assertEqual(
            steps[1]["blocks"][0]["content"][0]["value"],
            "ssw10-reindex-token-prod-read before anything else — it gates the first production merge.",
        )

    def test_generic_repair_collapses_evidence_wall_without_losing_source_text(self):
        sections = []
        for index in range(18):
            sections.extend(
                [
                    {
                        "type": "heading",
                        "level": 2,
                        "text": "Evidence {}".format(index),
                        "content": text("Evidence {}".format(index)),
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
        self.assertNotIn(
            "Evidence 2 Evidence 2",
            " ".join(block["summary"] for block in appendices),
        )

        second_document = {
            **document,
            "_rev": "second-rev",
            "blocks": repaired,
        }
        repaired_again = repair_canonical_epic(second_document)["mutations"][0][
            "patch"
        ]["set"]["blocks"]
        self.assertEqual(repaired_again, repaired)

        duplicated = copy.deepcopy(repaired)
        duplicated_appendix = next(
            block
            for block in duplicated
            if str(block.get("id", "")).startswith("epb-evidence-appendix-")
        )
        duplicated_appendix["summary"] = (
            "Evidence appendix 1 — Evidence 2 Evidence 2"
        )
        duplicated_orientation = next(
            block
            for block in duplicated
            if block.get("id") == "epb-cohort-orientation"
        )
        duplicated_orientation["items"] = [
            "Evidence 0 Evidence 0",
            "Evidence 1 Evidence 1",
            "Evidence 2 Evidence 2",
        ]
        healed = repair_canonical_epic(
            {**document, "_rev": "duplicated-rev", "blocks": duplicated}
        )["mutations"][0]["patch"]["set"]["blocks"]
        healed_appendix = next(
            block
            for block in healed
            if str(block.get("id", "")).startswith("epb-evidence-appendix-")
        )
        self.assertEqual(
            healed_appendix["summary"],
            "Evidence appendix 1 — Evidence 2",
        )
        healed_orientation = next(
            block
            for block in healed
            if block.get("id") == "epb-cohort-orientation"
        )
        self.assertEqual(
            healed_orientation["items"],
            ["Evidence 0", "Evidence 1", "Evidence 2"],
        )

    def test_repair_heals_duplicate_appendix_artifact_and_exposes_next_wave(self):
        appendices = [
            {
                "id": "epb-evidence-appendix-{}".format(index),
                "type": "expandable",
                "summary": "Evidence appendix {} — proof".format(index),
                "children": [
                    {"type": "heading", "level": 2, "text": "Proof {}".format(index)},
                    {"type": "paragraph", "content": text("Evidence {}".format(index))},
                ],
            }
            for index in range(1, 5)
        ]
        appendices.append(
            {
                "id": "epb-evidence-appendix-1",
                "type": "expandable",
                "summary": "Evidence appendix 1 — Next wave",
                "children": [
                    {"type": "heading", "level": 2, "text": "Next wave"},
                    {
                        "type": "steps",
                        "steps": [
                            {
                                "title": (
                                    "MERGE ROUND 1 — #7870 first, then #7864 + "
                                    "#7865 in either order (shared router file, "
                                    "different regions), then #7868."
                                ),
                                "blocks": [],
                            }
                        ],
                    },
                ],
            }
        )
        document = {
            "_id": "duplicate-appendix-repair",
            "_rev": "source-rev",
            "title": "Duplicate appendix repair",
            "description": "This wave restores the primary next action and unique proof rails.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {"type": "heading", "level": 1, "text": "Duplicate appendix repair"},
                {"type": "ingress", "content": text("The decision and its evidence.")},
                {"type": "stats", "items": [{"value": "5", "label": "actions"}]},
                *appendices,
            ],
        }

        repaired = repair_canonical_epic(document)["mutations"][0]["patch"]["set"][
            "blocks"
        ]
        generated = [
            block
            for block in repaired
            if block.get("type") == "expandable"
            and str(block.get("id", "")).startswith("epb-evidence-appendix-")
        ]
        self.assertEqual(
            [block["id"] for block in generated],
            ["epb-evidence-appendix-{}".format(index) for index in range(1, 5)],
        )
        self.assertTrue(
            any(
                block.get("type") == "heading"
                and block.get("text") == "Next wave"
                for block in repaired
            )
        )
        steps = next(block for block in repaired if block.get("type") == "steps")
        self.assertEqual(steps["steps"][0]["title"], "MERGE ROUND 1")

    def test_generic_repair_makes_nested_block_ids_globally_unique(self):
        document = {
            "_id": "nested-duplicate-ids",
            "_rev": "source-rev",
            "title": "Nested duplicate ids",
            "description": "This wave keeps every proof block addressable in every reader.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {"id": "heading", "type": "heading", "level": 1, "text": "Proof"},
                {
                    "id": "appendix-a",
                    "type": "expandable",
                    "summary": "Evidence appendix 1 — first",
                    "children": [
                        {
                            "id": "shared-proof",
                            "type": "paragraph",
                            "content": text("First proof"),
                        }
                    ],
                },
                {
                    "id": "appendix-b",
                    "type": "expandable",
                    "summary": "Evidence appendix 2 — second",
                    "children": [
                        {
                            "id": "shared-proof",
                            "type": "paragraph",
                            "content": text("Second proof"),
                        }
                    ],
                },
            ],
        }

        repaired = repair_canonical_epic(document)["mutations"][0]["patch"]["set"][
            "blocks"
        ]
        child_ids = [
            child["id"]
            for block in repaired
            if block.get("type") == "expandable"
            for child in block.get("children", [])
        ]
        self.assertEqual(child_ids, ["shared-proof", "shared-proof-copy-2"])

        repaired_again = repair_canonical_epic(
            {**document, "_rev": "second-rev", "blocks": repaired}
        )["mutations"][0]["patch"]["set"]["blocks"]
        self.assertEqual(repaired_again, repaired)


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

    def test_generic_repair_collapses_heading_dense_evidence_below_word_limit(self):
        evidence = []
        for index in range(1, 11):
            evidence.extend(
                [
                    {
                        "id": "section-{}".format(index),
                        "type": "heading",
                        "level": 2,
                        "text": "Evidence section {}".format(index),
                    },
                    {
                        "id": "finding-{}".format(index),
                        "type": "heading",
                        "level": 3,
                        "text": "Finding {}".format(index),
                    },
                    {
                        "id": "proof-{}".format(index),
                        "type": "paragraph",
                        "content": text("The proof remains exact."),
                    },
                ]
            )
        document = {
            "_id": "heading-dense-repair",
            "_rev": "source-rev",
            "title": "Heading-dense repair",
            "description": "This wave keeps the decision visible and its evidence bounded.",
            "tags": [{"tag": "epic-cycle-wave-paper"}],
            "blocks": [
                {
                    "id": "title",
                    "type": "heading",
                    "level": 1,
                    "text": "Heading-dense repair",
                },
                *evidence,
            ],
        }

        repaired = repair_canonical_epic(document)["mutations"][0]["patch"]["set"][
            "blocks"
        ]
        report = audit_papers([{**document, "blocks": repaired}])["papers"][0]

        self.assertTrue(report["pass"])
        self.assertEqual(report["warnings"], [])
        self.assertTrue(
            any(block.get("type") == "expandable" for block in repaired)
        )

        repaired_again = repair_canonical_epic(
            {**document, "_rev": "second-rev", "blocks": repaired}
        )["mutations"][0]["patch"]["set"]["blocks"]
        self.assertEqual(repaired_again, repaired)

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
