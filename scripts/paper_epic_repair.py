#!/usr/bin/env python3
"""Build revision-fenced editorial repairs for named epic Papers."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Optional

from paper_structure import canonicalize_blocks


SITE_SPAWNER_ID = "site-spawner-wave-10-2026-07-30"
SPACING_DOCTRINE_ID = "mechanical-spacing-doctrine"
CANONICAL_EPIC_TAG = "epic-cycle-wave-paper"
EPIC_TAG_SELECTIONS = {
    "source-of-truth-grip-wave-7-2026-07-21": [
        "ledger",
        "measurement",
        "cli",
        CANONICAL_EPIC_TAG,
    ],
    "source-of-truth-grip-wave-8-2026-07-21": [
        "design-doc",
        "measurement",
        CANONICAL_EPIC_TAG,
    ],
}
PAPER_AUTHORITY_BOUNDARIES = {
    "source-of-truth-grip-wave-2026-07-20": (
        "Authority boundary: This Paper remains authority for the Wave 1 "
        "level-skip contract and its first structural gate. Wave 8 carries "
        "the current epic state and finishing verdict."
    ),
    "source-of-truth-grip-wave-2-2026-07-20": (
        "Editorial status (historical authority): Wave 2 is complete and "
        "remains authority for the gate-directed fleet and recipe-ledger "
        "decisions. Wave 8 carries the current epic state and finishing verdict."
    ),
    "source-of-truth-grip-wave-3-2026-07-21": (
        "Authority boundary: This Paper remains authority for the Wave 3 CLI "
        "seam design and evidence-recording discipline. Wave 8 carries the "
        "current epic state and finishing verdict."
    ),
    "source-of-truth-grip-wave-4-2026-07-21": (
        "Authority boundary: This Paper remains authority for the Wave 4 first "
        "real ledger row and instrument contract. Wave 8 carries the current "
        "epic state and finishing verdict."
    ),
    "source-of-truth-grip-wave-5-2026-07-21": (
        "Authority boundary: This Paper remains authority for the Wave 5 "
        "corpus-migration attempt and its recorded limits. Wave 8 carries the "
        "current epic state and finishing verdict."
    ),
    "wsc-wave-2026-07-17": (
        "Editorial status (historical authority): Wave 2 remains authority for "
        "the reviewed s3 salvage and the D16 cross-surface seam. Wave 4 carries "
        "the current cockpit results and D46 steering decision."
    ),
    "wsc-wave-2026-07-18": (
        "Authority boundary: This Paper remains authority for the Wave 4 "
        "cockpit results and D46 fleet-steering decision. Live task state "
        "remains authoritative for subsequent implementation."
    ),
    "cloud-gui-remake-wave-2026-07-21-r12": (
        "Authority boundary: This Paper is the terminal code-seal authority for "
        "Cloud GUI Remake. Current follow-on work lives in Cloud Console "
        "Hardening; the seal does not claim the crown is live or the inherited "
        "backlog is solved."
    ),
    "portabledoc-blog-wave-1-2026-07-15": (
        "Authority boundary: This founding Paper remains authority for the "
        "canonical JavaScript renderer foundation and its original parity "
        "contract. Later render-unification waves own migration, hardening, "
        "and final coverage."
    ),
    "portabledoc-render-unification-w5-2026-07-16": (
        "Authority boundary: This historical Paper remains authority for the "
        "Wave 5 web-fork retirement and blog-starter migration decisions. "
        "Wave 6 owns the distinct hardening proofs; Wave 7 owns the final "
        "parity-closure decision."
    ),
    "site-spawner-wave-2026-07-13": (
        "Authority boundary: This founding Paper remains authority for the "
        "initial six-stage deploy spine, adapter-by-runtime architecture, and "
        "static Astro scope. Later Site Spawner waves own current "
        "implementation and live deployment evidence."
    ),
}
PAPER_TITLE_OVERRIDES = {
    "cloud-gui-remake-wave-2026-07-21-r12": (
        "Cloud GUI Remake — round 12: the two mechanical acts, and the verdict"
    ),
}
SITE_SPAWNER_NOTE_LISTS = {
    "l-907": "verdict",
    "l-d022": "conflict",
    "l-d027": "evidence",
    "l-d032": "gap",
    "l-d037": "question",
    "l-717": "finding",
    "l-731": "residual",
    "l-925": "proof",
    "l-948": "ledger",
}
SITE_SPAWNER_STEP_LISTS = {"l-964"}
SITE_SPAWNER_NOTE_TABLES = {
    "t-057": "headed",
    "t-d010": "two-column",
    "t-507": "first-row-header",
}
SITE_SPAWNER_OPENING_IDS = {
    "epb-opening-ingress",
    "epb-opening-byline",
    "epb-opening-stats",
}
SITE_SPAWNER_WISH_HEADING_ID = "epb-owner-wish-heading"


def _inline_text(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        return " ".join(filter(None, (_inline_text(item) for item in value)))
    if isinstance(value, dict):
        for key in ("value", "text", "content"):
            if key in value:
                return _inline_text(value[key])
    return ""


def _normalize(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def _normalize_prose(value: str) -> str:
    return re.sub(r"\s+([,.;:!?])", r"\1", _normalize(value))


class _LegacyHtmlBlockParser(HTMLParser):
    """Recover the semantic reading order of a legacy HTML-only Paper.

    This is deliberately a small, lossless text bridge, not a general HTML
    importer. It recognizes the authored block vocabulary used by the legacy
    wave Papers: headings, paragraphs, ordered/unordered lists, quotes, code
    panels, and dividers. Inline markup contributes text to its parent block.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.blocks: list[dict[str, Any]] = []
        self._buffer: list[str] = []
        self._active_tag: Optional[str] = None
        self._active_type: Optional[str] = None
        self._active_level: Optional[int] = None
        self._list_depth = 0
        self._list_style: Optional[str] = None
        self._list_items: list[list[dict[str, str]]] = []
        self._in_list_item = False

    def _next_id(self) -> str:
        return f"legacy-html-{len(self.blocks) + 1:03d}"

    def _start_text_block(
        self,
        tag: str,
        block_type: str,
        *,
        level: Optional[int] = None,
    ) -> None:
        if self._active_tag is not None:
            return
        self._active_tag = tag
        self._active_type = block_type
        self._active_level = level
        self._buffer = []

    def _finish_text_block(self, tag: str) -> None:
        if self._active_tag != tag:
            return
        value = _normalize("".join(self._buffer))
        if value:
            block: dict[str, Any] = {
                "id": self._next_id(),
                "type": self._active_type,
            }
            if self._active_type == "heading":
                block["level"] = self._active_level
                block["text"] = value
            elif self._active_type == "code":
                block["value"] = value
            elif self._active_type == "quote":
                block["text"] = value
            else:
                block["content"] = [{"type": "text", "value": value}]
            self.blocks.append(block)
        self._active_tag = None
        self._active_type = None
        self._active_level = None
        self._buffer = []

    def handle_starttag(
        self,
        tag: str,
        attrs: list[tuple[str, Optional[str]]],
    ) -> None:
        del attrs
        tag = tag.casefold()
        if tag in {"ul", "ol"}:
            if self._list_depth == 0:
                self._list_style = "ordered" if tag == "ol" else "bullet"
                self._list_items = []
            self._list_depth += 1
            return
        if tag == "li" and self._list_depth:
            self._in_list_item = True
            self._buffer = []
            return
        if self._in_list_item:
            if tag == "br":
                self._buffer.append(" ")
            return
        if tag in {f"h{level}" for level in range(1, 7)}:
            self._start_text_block(tag, "heading", level=int(tag[1]))
        elif tag == "p":
            self._start_text_block(tag, "paragraph")
        elif tag == "blockquote":
            self._start_text_block(tag, "quote")
        elif tag == "pre":
            self._start_text_block(tag, "code")
        elif tag == "hr":
            self.blocks.append({"id": self._next_id(), "type": "divider"})
        elif tag == "br" and self._active_tag is not None:
            self._buffer.append(" ")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.casefold()
        if tag == "li" and self._list_depth and self._in_list_item:
            value = _normalize("".join(self._buffer))
            if value:
                self._list_items.append([{"type": "text", "value": value}])
            self._buffer = []
            self._in_list_item = False
            return
        if tag in {"ul", "ol"} and self._list_depth:
            self._list_depth -= 1
            if self._list_depth == 0 and self._list_items:
                self.blocks.append(
                    {
                        "id": self._next_id(),
                        "type": "list",
                        "style": self._list_style,
                        "items": copy.deepcopy(self._list_items),
                    }
                )
                self._list_items = []
                self._list_style = None
            return
        if tag == "pre":
            self._finish_text_block(tag)
            return
        self._finish_text_block(tag)

    def handle_data(self, data: str) -> None:
        if self._in_list_item or self._active_tag is not None:
            self._buffer.append(data)


def legacy_html_to_blocks(source_html: str) -> list[dict[str, Any]]:
    """Convert a legacy HTML-only Paper into deterministic semantic blocks."""
    if not isinstance(source_html, str) or not _normalize(source_html):
        raise ValueError("legacy source HTML must be non-empty")
    parser = _LegacyHtmlBlockParser()
    parser.feed(source_html)
    parser.close()
    if not parser.blocks:
        raise ValueError("legacy source HTML produced no semantic blocks")
    return parser.blocks


def _apply_authority_boundary(
    blocks: list[Any],
    paper_id: str,
) -> list[Any]:
    boundary = PAPER_AUTHORITY_BOUNDARIES.get(paper_id)
    if boundary is None:
        return copy.deepcopy(blocks)

    repaired = copy.deepcopy(blocks)
    editorial_index = next(
        (
            index
            for index, block in enumerate(repaired)
            if isinstance(block, dict)
            and block.get("type") == "callout"
            and _inline_text(block.get("content"))
            .casefold()
            .startswith("editorial status")
        ),
        None,
    )
    if (
        paper_id == "portabledoc-render-unification-w5-2026-07-16"
        and editorial_index is not None
    ):
        callout = repaired[editorial_index]
        original = _normalize(_inline_text(callout.get("content")))
        if "Authority boundary:" in original:
            original = original.split("Authority boundary:", 1)[0].strip()
        callout["content"] = [
            {
                "type": "text",
                "value": "{} {}".format(original, boundary),
            }
        ]
        return repaired

    if any(boundary in _inline_text(block) for block in repaired):
        return repaired

    if editorial_index is not None:
        callout = repaired[editorial_index]
        original = _normalize(_inline_text(callout.get("content")))
        callout["content"] = [
            {
                "type": "text",
                "value": "{} {}".format(original, boundary),
            }
        ]
        return repaired

    authority_callout = {
        "id": "epb-authority-boundary",
        "type": "callout",
        "tone": "info",
        "content": [{"type": "text", "value": boundary}],
    }
    h1_index = next(
        (
            index
            for index, block in enumerate(repaired)
            if isinstance(block, dict)
            and block.get("type") == "heading"
            and block.get("level") == 1
        ),
        0,
    )
    repaired.insert(h1_index, authority_callout)
    return repaired


def _split_lead(value: str) -> tuple[str, str]:
    text = _normalize(value)
    match = re.search(r"(?<=[.!?])\s+", text)
    if match is None:
        return text, ""
    return text[: match.start()].strip(), text[match.end() :].strip()


def _split_compact_lead(
    value: str,
    *,
    force_boundary: bool = False,
) -> tuple[str, str]:
    normalized = _normalize(value)
    lead, text = _split_lead(normalized)
    if (
        not force_boundary
        and len(lead.split()) <= 16
        and (text or len(lead.split()) <= 16)
    ):
        return lead, text

    # Prefer authored clause boundaries over an arbitrary word budget. Keep the
    # separator with the body so joining title + body reconstructs the original
    # visible text byte-for-meaning while the title remains a complete action.
    for match in re.finditer(r"\s+(?=(?:—|–|-)\s+)|(?<=[:,;])\s+", normalized):
        title = normalized[: match.start()].strip()
        body = normalized[match.end() :].strip()
        if 3 <= len(title.split()) <= 16 and body:
            return title, body

    # Parenthetical evidence belongs in the body. This explicitly prevents the
    # old "(shared router" / "(do_rollback" mid-phrase title cuts.
    for match in re.finditer(r"\s+(?=\()", normalized):
        title = normalized[: match.start()].strip()
        body = normalized[match.end() :].strip()
        if 3 <= len(title.split()) <= 16 and body:
            return title, body

    # Explanatory subordinators are the next safest semantic seam.
    for match in re.finditer(
        r"\s+(?=(?:because|so that|so|while|when|which|where|after|before|then)\b)",
        normalized,
        flags=re.IGNORECASE,
    ):
        title = normalized[: match.start()].strip()
        body = normalized[match.end() :].strip()
        if 3 <= len(title.split()) <= 16 and body:
            return title, body

    words = normalized.split()
    return " ".join(words[:16]), " ".join(words[16:])


def _is_empty_paragraph(block: Any) -> bool:
    return (
        isinstance(block, dict)
        and block.get("type") == "paragraph"
        and block.get("content") in (None, [])
        and not _normalize(str(block.get("text") or ""))
    )


def _list_as_notes(block: dict[str, Any], label: str) -> dict[str, Any]:
    items = block.get("items")
    if not isinstance(items, list):
        raise ValueError("{} is not a list block".format(block.get("id")))
    notes = []
    for index, item in enumerate(items, start=1):
        original = _inline_text(item)
        lead, text = _split_lead(original)
        if _normalize("{} {}".format(lead, text)) != _normalize(original):
            raise AssertionError("list reframe changed factual text")
        notes.append(
            {
                "label": "{} {:02d}".format(label, index),
                "lead": lead,
                "text": text,
            }
        )
    return {"id": block["id"], "type": "notes", "items": notes}


def _list_as_steps(block: dict[str, Any]) -> dict[str, Any]:
    items = block.get("items")
    if not isinstance(items, list):
        raise ValueError("{} is not a list block".format(block.get("id")))
    steps = []
    for item in items:
        original = _inline_text(item)
        title, body = _split_lead(original)
        if _normalize("{} {}".format(title, body)) != _normalize(original):
            raise AssertionError("step reframe changed factual text")
        step = {"title": title}
        if body:
            step["blocks"] = [
                {
                    "type": "paragraph",
                    "content": [{"type": "text", "value": body}],
                }
            ]
        else:
            step["blocks"] = []
        steps.append(step)
    return {"id": block["id"], "type": "steps", "steps": steps}


def _table_as_notes(block: dict[str, Any], mode: str) -> dict[str, Any]:
    rows = copy.deepcopy(block.get("rows"))
    if not isinstance(rows, list):
        raise ValueError("{} is not a table block".format(block.get("id")))
    if mode == "first-row-header":
        if not rows:
            raise ValueError("{} has no header row".format(block.get("id")))
        rows = rows[1:]

    notes = []
    for index, row in enumerate(rows, start=1):
        if not isinstance(row, list):
            raise ValueError("{} has a non-array row".format(block.get("id")))
        cells = [_inline_text(cell) for cell in row]
        if mode in ("headed", "first-row-header") and len(cells) >= 3:
            label, lead, text = cells[0], cells[1], " ".join(cells[2:])
        elif mode == "two-column" and len(cells) >= 2:
            label = "finding {:02d}".format(index)
            lead, text = cells[0], " ".join(cells[1:])
        else:
            raise ValueError("{} has an unexpected row shape".format(block.get("id")))
        notes.append({"label": label, "lead": lead, "text": text})

        original = _normalize(" ".join(cells))
        reframed = _normalize(
            " ".join(
                part
                for part in (label if mode != "two-column" else "", lead, text)
                if part
            )
        )
        if original != reframed:
            raise AssertionError("table reframe changed factual text")

    return {"id": block["id"], "type": "notes", "items": notes}


def _visible_text(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        return " ".join(filter(None, (_visible_text(item) for item in value)))
    if not isinstance(value, dict):
        return ""
    if value.get("type") == "steps":
        steps = value.get("steps")
        if isinstance(steps, list):
            return " ".join(
                filter(
                    None,
                    (
                        "{} {}".format(
                            _visible_text(step.get("title")),
                            _visible_text(step.get("blocks")),
                        ).strip()
                        for step in steps
                        if isinstance(step, dict)
                    ),
                )
            )
    if value.get("type") == "expandable":
        return "{} {}".format(
            _visible_text(value.get("summary")),
            _visible_text(value.get("children")),
        ).strip()
    return " ".join(
        filter(
            None,
            (
                _visible_text(value.get(key))
                for key in (
                    "alt",
                    "blocks",
                    "caption",
                    "children",
                    "content",
                    "description",
                    "head",
                    "items",
                    "label",
                    "lead",
                    "rows",
                    "steps",
                    "subtitle",
                    "summary",
                    "text",
                    "title",
                    "value",
                )
            ),
        )
    )


def _uniquify_block_ids(blocks: list[Any]) -> list[Any]:
    """Keep the first authored id and deterministically rename later collisions."""
    repaired = copy.deepcopy(blocks)
    seen: set[str] = set()
    next_copy: dict[str, int] = {}

    def visit_block(block: Any) -> None:
        if not isinstance(block, dict):
            return

        block_id = block.get("id")
        if isinstance(block_id, str) and block_id:
            if block_id in seen:
                copy_index = next_copy.get(block_id, 2)
                candidate = "{}-copy-{}".format(block_id, copy_index)
                while candidate in seen:
                    copy_index += 1
                    candidate = "{}-copy-{}".format(block_id, copy_index)
                block["id"] = candidate
                next_copy[block_id] = copy_index + 1
                seen.add(candidate)
            else:
                seen.add(block_id)
                next_copy.setdefault(block_id, 2)

        for key in ("children", "blocks"):
            children = block.get(key)
            if isinstance(children, list):
                for child in children:
                    visit_block(child)

        child = block.get("child")
        if isinstance(child, dict):
            visit_block(child)

        if block.get("type") == "steps":
            steps = block.get("steps")
            if isinstance(steps, list):
                for step in steps:
                    if not isinstance(step, dict):
                        continue
                    step_blocks = step.get("blocks")
                    if isinstance(step_blocks, list):
                        for step_block in step_blocks:
                            visit_block(step_block)

    for top_level in repaired:
        visit_block(top_level)
    return repaired


def _visible_leaf_texts(value: Any) -> list[str]:
    if isinstance(value, str):
        return [_normalize(value)] if _normalize(value) else []
    if isinstance(value, list):
        return [
            leaf
            for item in value
            for leaf in _visible_leaf_texts(item)
        ]
    if not isinstance(value, dict):
        return []

    leaves = []
    for key in (
        "alt",
        "blocks",
        "caption",
        "children",
        "content",
        "description",
        "head",
        "items",
        "label",
        "lead",
        "rows",
        "steps",
        "subtitle",
        "summary",
        "text",
        "title",
        "value",
    ):
        leaves.extend(_visible_leaf_texts(value.get(key)))
    return leaves


def _canonical_tagged(document: dict[str, Any]) -> bool:
    for tag in document.get("tags", []):
        if tag == CANONICAL_EPIC_TAG:
            return True
        if isinstance(tag, dict) and tag.get("tag") == CANONICAL_EPIC_TAG:
            return True
    return False


def _tag_name(tag: Any) -> str:
    if isinstance(tag, str):
        return tag
    if isinstance(tag, dict):
        return str(tag.get("tag") or "")
    return ""


def _curate_epic_tags(document: dict[str, Any]) -> tuple[list[Any], Optional[str]]:
    tags = document.get("tags")
    if not isinstance(tags, list):
        return [], None

    by_name = {
        _tag_name(tag): copy.deepcopy(tag)
        for tag in tags
        if _tag_name(tag)
    }
    paper_id = str(document.get("_id") or "")
    selected_names = EPIC_TAG_SELECTIONS.get(paper_id)
    if selected_names is None and len(tags) <= 4:
        return copy.deepcopy(tags), None

    if selected_names is None:
        main_tag = str(document.get("main_tag") or "")
        selected_names = [CANONICAL_EPIC_TAG]
        if main_tag and main_tag in by_name and main_tag != CANONICAL_EPIC_TAG:
            selected_names.append(main_tag)
        selected_names.extend(
            name
            for name in by_name
            if name not in selected_names
        )
        selected_names = selected_names[:4]

    curated = [
        by_name[name]
        for name in selected_names
        if name in by_name
    ]
    if CANONICAL_EPIC_TAG not in {_tag_name(tag) for tag in curated}:
        curated.append(
            by_name.get(
                CANONICAL_EPIC_TAG,
                {"tag": CANONICAL_EPIC_TAG},
            )
        )
    curated = curated[:4]

    main_tag = str(document.get("main_tag") or "")
    curated_names = [_tag_name(tag) for tag in curated]
    if main_tag not in curated_names:
        main_tag = next(
            (name for name in curated_names if name != CANONICAL_EPIC_TAG),
            CANONICAL_EPIC_TAG,
        )
        return curated, main_tag
    return curated, None


def _long_list(block: dict[str, Any]) -> bool:
    items = block.get("items")
    return (
        block.get("type") == "list"
        and isinstance(items, list)
        and any(len(_visible_text(item).split()) > 40 for item in items)
    )


def _generic_list_as_notes(block: dict[str, Any]) -> dict[str, Any]:
    items = block.get("items")
    if not isinstance(items, list):
        raise ValueError("{} is not a list block".format(block.get("id")))

    notes = []
    for index, item in enumerate(items, start=1):
        original = _visible_text(item)
        lead, text = _split_compact_lead(original)
        if _normalize("{} {}".format(lead, text)) != _normalize(original):
            raise AssertionError("generic list reframe changed factual text")
        notes.append(
            {
                "label": "point {:02d}".format(index),
                "lead": lead,
                "text": text,
            }
        )

    repaired = copy.deepcopy(block)
    repaired["type"] = "notes"
    repaired["items"] = notes
    return repaired


def _split_table(block: dict[str, Any]) -> list[dict[str, Any]]:
    rows = block.get("rows")
    if block.get("type") != "table" or not isinstance(rows, list):
        return [block]
    if len(rows) <= 12:
        return [block]

    chunks = []
    for index, offset in enumerate(range(0, len(rows), 12), start=1):
        chunk = copy.deepcopy(block)
        chunk["id"] = "{}-part-{}".format(
            block.get("id", "table"),
            index,
        )
        chunk["rows"] = copy.deepcopy(rows[offset : offset + 12])
        chunks.append(chunk)
    return chunks


def _promote_table_head(block: dict[str, Any]) -> dict[str, Any]:
    if block.get("type") != "table":
        return block
    rows = block.get("rows")
    head = block.get("head")
    if not isinstance(rows, list) or not rows or (
        isinstance(head, list) and head
    ):
        return block

    repaired = copy.deepcopy(block)
    repaired["head"] = copy.deepcopy(rows[0])
    repaired["rows"] = copy.deepcopy(rows[1:])
    return repaired


def _repair_steps(block: dict[str, Any]) -> dict[str, Any]:
    steps = block.get("steps")
    if block.get("type") != "steps" or not isinstance(steps, list):
        return block

    repaired = copy.deepcopy(block)
    repaired_steps = []
    for step in steps:
        if not isinstance(step, dict):
            repaired_steps.append(copy.deepcopy(step))
            continue

        repaired_step = copy.deepcopy(step)
        original_title = _normalize(str(repaired_step.get("title") or ""))
        children = repaired_step.get("blocks")
        children = copy.deepcopy(children) if isinstance(children, list) else []
        split_source = original_title

        # An older repair could move an arbitrary title suffix into a generated
        # first paragraph. Heal that shape before choosing a better semantic
        # boundary. A lowercase/non-letter continuation or unbalanced
        # parenthesis is evidence that the first paragraph continues the title;
        # a normal authored body starts a new sentence and remains untouched.
        first_body = _normalize(_visible_text(children[0])) if children else ""
        first_alpha = re.search(r"[A-Za-z]", first_body)
        continues_title = bool(
            first_body
            and (
                original_title.count("(") > original_title.count(")")
                or first_alpha is None
                or first_alpha.group(0).islower()
            )
        )
        if continues_title:
            split_source = _normalize("{} {}".format(original_title, first_body))
            children = children[1:]

        if len(split_source.split()) > 16 or continues_title:
            title, body = _split_compact_lead(
                split_source,
                force_boundary=continues_title,
            )
            repaired_step["title"] = title
            if body:
                children.insert(
                    0,
                    {
                        "type": "paragraph",
                        "content": [{"type": "text", "value": body}],
                    },
                )
            repaired_step["blocks"] = children

            repaired_body = (
                _visible_text(repaired_step["blocks"][0])
                if repaired_step["blocks"]
                else ""
            )
            if _normalize(
                "{} {}".format(
                    repaired_step["title"],
                    repaired_body,
                )
            ) != split_source:
                raise AssertionError("step repair changed title text")
        elif continues_title:
            repaired_step["title"] = split_source
            repaired_step["blocks"] = children

        repaired_steps.append(repaired_step)

    repaired["steps"] = repaired_steps
    return repaired


def _dedupe_callout_title(block: dict[str, Any]) -> dict[str, Any]:
    if block.get("type") != "callout":
        return block
    title = _normalize(str(block.get("title") or ""))
    content = _normalize(_visible_text(block.get("content")))
    if not title or not content.casefold().startswith(title.casefold()):
        return block

    repaired = copy.deepcopy(block)
    repaired.pop("title", None)
    return repaired


def _redundant_callout_titles(blocks: list[Any]) -> set[str]:
    """Return titles whose callout body already opens with the same label."""
    titles = set()
    for block in blocks:
        if not isinstance(block, dict) or block.get("type") != "callout":
            continue
        title = _normalize(str(block.get("title") or ""))
        content = _normalize(_visible_text(block.get("content")))
        if title and content.casefold().startswith(title.casefold()):
            titles.add(title)
    return titles


def _repair_nested_blocks(value: Any) -> Any:
    if isinstance(value, list):
        return [_repair_nested_blocks(item) for item in value]
    if not isinstance(value, dict):
        return value

    repaired = copy.deepcopy(value)
    for key, child in list(repaired.items()):
        if key in {"blocks", "children"} and isinstance(child, list):
            repaired[key] = _repair_block_sequence(child)
        elif isinstance(child, (dict, list)):
            repaired[key] = _repair_nested_blocks(child)
    return repaired


def _repair_block_sequence(blocks: list[Any]) -> list[Any]:
    repaired = []
    for source in blocks:
        if _is_empty_paragraph(source):
            continue
        if not isinstance(source, dict):
            repaired.append(copy.deepcopy(source))
            continue

        block = _repair_nested_blocks(source)
        level = block.get("level")
        if block.get("type") == "heading" and isinstance(level, str) and level.isdigit():
            block["level"] = int(level)

        block = _promote_table_head(block)
        block = _repair_steps(block)
        block = _dedupe_callout_title(block)

        if _long_list(block):
            block = _generic_list_as_notes(block)

        repaired.extend(_split_table(block))
    return repaired


def _heading_text(block: dict[str, Any]) -> str:
    text = _normalize(str(block.get("text") or ""))
    if text:
        return text
    return _normalize(_visible_text(block.get("content")))


def _word_count(value: Any) -> int:
    return len(_visible_text(value).split())


def _dense_primary_block(block: Any) -> bool:
    if not isinstance(block, dict):
        return False
    block_type = block.get("type")
    if block_type == "paragraph":
        return _word_count(block) > 140
    if block_type == "notes":
        items = block.get("items")
        return isinstance(items, list) and any(
            _word_count(item) > 80 for item in items
        )
    if block_type == "table":
        rows = block.get("rows")
        return isinstance(rows, list) and any(
            _word_count(cell) > 60
            for row in rows
            if isinstance(row, list)
            for cell in row
        )
    return False


def _dense_block_summary(block: dict[str, Any], index: int) -> str:
    block_type = block.get("type")
    if block_type == "paragraph":
        words = _visible_text(block).split()
        lead = " ".join(words[:12])
        return "Detail — {}{}".format(lead, "…" if len(words) > 12 else "")
    if block_type == "notes":
        items = block.get("items")
        first = items[0] if isinstance(items, list) and items else {}
        label = _normalize(str(first.get("label") or "")) if isinstance(first, dict) else ""
        return "Evidence notes{}".format(" — {}".format(label) if label else "")
    if block_type == "table":
        head = block.get("head")
        labels = (
            [_visible_text(cell) for cell in head]
            if isinstance(head, list)
            else []
        )
        labels = [label for label in labels if label]
        return "Evidence table{}".format(
            " — {}".format(" · ".join(labels[:3])) if labels else ""
        )
    return "Evidence detail {}".format(index)


def _collapse_dense_primary_blocks(blocks: list[Any]) -> list[Any]:
    repaired = []
    for index, block in enumerate(blocks, start=1):
        if _dense_primary_block(block):
            repaired.append(
                {
                    "id": "epb-dense-detail-{}".format(index),
                    "type": "expandable",
                    "summary": _dense_block_summary(block, index),
                    "children": [copy.deepcopy(block)],
                }
            )
        else:
            repaired.append(block)
    return repaired


def _is_generated_appendix(block: Any) -> bool:
    return (
        isinstance(block, dict)
        and block.get("type") == "expandable"
        and (
            str(block.get("id") or "").startswith("epb-evidence-appendix-")
            or re.match(
                r"^Evidence appendix \d+\b",
                _normalize(str(block.get("summary") or "")),
            )
            is not None
        )
    )


def _repair_existing_appendices(blocks: list[Any]) -> list[Any]:
    """Heal repeat-pass appendix artifacts without hiding the primary tail."""
    generated = [block for block in blocks if _is_generated_appendix(block)]
    if not generated:
        return blocks

    ids = [str(block.get("id") or "") for block in generated]
    summaries = [_normalize(str(block.get("summary") or "")) for block in generated]
    numbers = []
    for summary in summaries:
        match = re.match(r"^Evidence appendix (\d+)\b", summary)
        numbers.append(int(match.group(1)) if match else None)

    duplicate_artifact = len(set(ids)) != len(ids) or (
        len([number for number in numbers if number is not None])
        != len(set(number for number in numbers if number is not None))
    )
    overflow_artifact = len(generated) > 4

    repaired: list[Any] = []
    appendix_index = 0
    for block in blocks:
        if not _is_generated_appendix(block):
            repaired.append(block)
            continue

        appendix_index += 1
        children = block.get("children")
        if (
            (duplicate_artifact or overflow_artifact)
            and appendix_index > 4
            and isinstance(children, list)
            and _word_count(children) <= 700
        ):
            repaired.extend(copy.deepcopy(children))
            continue

        normalized = copy.deepcopy(block)
        normalized["id"] = "epb-evidence-appendix-{}".format(appendix_index)
        first_heading = next(
            (
                child
                for child in children or []
                if isinstance(child, dict)
                and child.get("type") == "heading"
            ),
            None,
        )
        if first_heading is not None:
            first = " ".join(_heading_text(first_heading).split()[:14])
            summary = "Evidence appendix {} — {}".format(appendix_index, first)
        else:
            summary = "Evidence appendix {}".format(appendix_index)
        normalized["summary"] = summary
        repaired.append(normalized)

    return repaired


def _collapse_evidence_appendices(blocks: list[Any]) -> list[Any]:
    blocks = _repair_existing_appendices(blocks)
    # A canonical repair has already established the appendix boundary. Never
    # feed its collapsed children back through the top-level chunker.
    if any(_is_generated_appendix(block) for block in blocks):
        return blocks

    primary_words = len(_visible_text(blocks).split())
    top_level_heading_count = sum(
        1
        for block in blocks
        if isinstance(block, dict) and block.get("type") == "heading"
    )
    h2_indexes = [
        index
        for index, block in enumerate(blocks)
        if isinstance(block, dict)
        and block.get("type") == "heading"
        and block.get("level") == 2
    ]
    if (
        primary_words <= 5_000
        and len(blocks) <= 80
        and top_level_heading_count <= 16
    ):
        return blocks
    if len(h2_indexes) <= 2:
        return blocks

    prefix = copy.deepcopy(blocks[: h2_indexes[0]])
    sections = []
    for position, start in enumerate(h2_indexes):
        stop = h2_indexes[position + 1] if position + 1 < len(h2_indexes) else len(blocks)
        sections.append(copy.deepcopy(blocks[start:stop]))

    visible_sections = sections[:2]
    appendix_sections = sections[2:]
    if not appendix_sections:
        return blocks
    visible_tail = []
    if len(appendix_sections) > 1 and len(
        _visible_text(appendix_sections[-1]).split()
    ) <= 700:
        visible_tail = appendix_sections[-1:]
        appendix_sections = appendix_sections[:-1]

    appendix_count = min(4, len(appendix_sections))
    chunk_size = (len(appendix_sections) + appendix_count - 1) // appendix_count
    appendices = []
    for index, offset in enumerate(
        range(0, len(appendix_sections), chunk_size),
        start=1,
    ):
        chunk = appendix_sections[offset : offset + chunk_size]
        children = [block for section in chunk for block in section]
        first = _heading_text(chunk[0][0])
        first = " ".join(first.split()[:14])
        appendices.append(
            {
                "id": "epb-evidence-appendix-{}".format(index),
                "type": "expandable",
                "summary": "Evidence appendix {} — {}".format(index, first),
                "children": children,
            }
        )

    return (
        prefix
        + [block for section in visible_sections for block in section]
        + appendices
        + [block for section in visible_tail for block in section]
    )


def _opening_orientation_items(blocks: list[Any]) -> list[str]:
    def headings(values: list[Any]) -> Iterator[dict[str, Any]]:
        for value in values:
            if not isinstance(value, dict):
                continue
            if value.get("type") == "heading":
                yield value
            for key in ("children", "blocks"):
                nested = value.get(key)
                if isinstance(nested, list):
                    yield from headings(nested)

    items = []
    for block in headings(blocks):
        if block.get("level") == 1:
            continue
        heading = _heading_text(block)
        if heading and heading not in items:
            items.append(heading)
        if len(items) == 3:
            return items

    for fallback in (
        "Decision record",
        "Evidence and implications",
        "Next action",
    ):
        if fallback not in items:
            items.append(fallback)
        if len(items) == 3:
            break
    return items


def repair_canonical_epic(
    document: dict[str, Any],
    *,
    _require_canonical_tag: bool = True,
    _curate_canonical_tags: bool = True,
    _move_h1_first: bool = True,
    _derive_description: bool = False,
) -> dict[str, Any]:
    if _require_canonical_tag and not _canonical_tagged(document):
        raise ValueError("profile requires the exact {} tag".format(CANONICAL_EPIC_TAG))

    paper_id = document.get("_id")
    revision = document.get("_rev")
    blocks = document.get("blocks")
    description = _normalize(str(document.get("description") or ""))
    title = _normalize(str(document.get("title") or paper_id or ""))
    if not isinstance(paper_id, str) or not isinstance(revision, str):
        raise ValueError("Paper requires an id and revision")
    if not isinstance(blocks, list):
        raise ValueError("Paper requires a block array")
    if not description and _derive_description:
        description = next(
            (
                _normalize_prose(_visible_text(block))
                for block in blocks
                if isinstance(block, dict) and block.get("type") == "ingress"
                and _normalize_prose(_visible_text(block))
            ),
            "",
        )
    if not description:
        raise ValueError("canonical Epic Paper requires a meaningful description")

    blocks = _apply_authority_boundary(blocks, paper_id)
    source_leaves = _visible_leaf_texts(blocks)
    # Generated appendix summaries are repair chrome, not authored evidence.
    # A corrective pass may renumber or unwrap them while preserving every
    # child leaf. Do not mistake removal of stale synthetic chrome for factual
    # loss.
    generated_summaries = {
        _normalize(str(block.get("summary") or ""))
        for block in blocks
        if _is_generated_appendix(block)
    }
    redundant_callout_titles = _redundant_callout_titles(blocks)
    source_leaves = [
        leaf
        for leaf in source_leaves
        if leaf not in generated_summaries
        and leaf not in redundant_callout_titles
    ]
    repaired = _repair_block_sequence(canonicalize_blocks(blocks))

    h1_indexes = [
        index
        for index, block in enumerate(repaired)
        if isinstance(block, dict)
        and block.get("type") == "heading"
        and block.get("level") == 1
    ]
    if not h1_indexes:
        repaired.insert(
            0,
            {
                "id": "epb-cohort-h1",
                "type": "heading",
                "level": 1,
                "text": title,
            },
        )
        h1_index = 0
    else:
        h1_index = h1_indexes[0]
        for index in h1_indexes[1:]:
            repaired[index]["level"] = 2
        if _move_h1_first and h1_index != 0:
            h1 = repaired.pop(h1_index)
            repaired.insert(0, h1)
            h1_index = 0

    generated_orientation = next(
        (
            block
            for block in repaired
            if isinstance(block, dict)
            and block.get("id") == "epb-cohort-orientation"
            and block.get("type") == "byline"
        ),
        None,
    )
    if generated_orientation is not None:
        generated_orientation["items"] = _opening_orientation_items(repaired)

    opening_types = {
        block.get("type")
        for block in repaired[:8]
        if isinstance(block, dict)
    }
    insert_at = h1_index + 1
    if "ingress" not in opening_types:
        repaired.insert(
            insert_at,
            {
                "id": "epb-cohort-ingress",
                "type": "ingress",
                "content": [{"type": "text", "value": description}],
            },
        )
        insert_at += 1
    else:
        ingress_index = next(
            (
                index
                for index, block in enumerate(repaired[:8])
                if isinstance(block, dict) and block.get("type") == "ingress"
            ),
            None,
        )
        if ingress_index is not None:
            insert_at = ingress_index + 1

    opening_types = {
        block.get("type")
        for block in repaired[:8]
        if isinstance(block, dict)
    }
    if not opening_types.intersection({"byline", "stats", "toc", "list", "steps"}):
        repaired.insert(
            insert_at,
            {
                "id": "epb-cohort-orientation",
                "type": "byline",
                "items": _opening_orientation_items(repaired),
            },
        )

    repaired = _collapse_evidence_appendices(repaired)
    repaired = _collapse_dense_primary_blocks(repaired)
    repaired = _uniquify_block_ids(repaired)

    repaired_text = _normalize(_visible_text(repaired))
    missing_leaves = [
        leaf for leaf in source_leaves if leaf and leaf not in repaired_text
    ]
    if missing_leaves:
        raise AssertionError(
            "repair lost source text leaves: {}".format(missing_leaves[:3])
        )

    patch_set = {"blocks": repaired}
    if _derive_description and not _normalize(str(document.get("description") or "")):
        patch_set["description"] = description
    if _curate_canonical_tags:
        curated_tags, repaired_main_tag = _curate_epic_tags(document)
        if curated_tags != document.get("tags"):
            patch_set["tags"] = curated_tags
        if repaired_main_tag is not None:
            patch_set["main_tag"] = repaired_main_tag
    if title == paper_id:
        repaired_title = _normalize(_visible_text(repaired[h1_index]))
        if repaired_title:
            patch_set["title"] = repaired_title
    title_override = PAPER_TITLE_OVERRIDES.get(paper_id)
    if title_override is not None and title_override != document.get("title"):
        patch_set["title"] = title_override

    return {
        "mutations": [
            {
                "patch": {
                    "id": paper_id,
                    "type": "paper",
                    "ifRevisionID": revision,
                    "set": patch_set,
                }
            },
            {"publish": {"id": paper_id, "type": "paper"}},
        ]
    }


def repair_strategic_paper(document: dict[str, Any]) -> dict[str, Any]:
    """Apply the lossless authored-reading repair without changing taxonomy."""
    return repair_canonical_epic(
        document,
        _require_canonical_tag=False,
        _curate_canonical_tags=False,
        _move_h1_first=False,
        _derive_description=True,
    )


def repair_strategic_paper_from_html(
    document: dict[str, Any],
    source_html: str,
) -> dict[str, Any]:
    """Recover a legacy HTML-only source before applying strategic repair.

    Some historical Papers were later replaced by two pieces of editorial
    chrome. Recovery keeps the current editorial-status callout, reconstructs
    the authored semantic blocks from an immutable history snapshot, and
    applies the same revision fence and loss checks as every other repair.
    """
    recovered_blocks = legacy_html_to_blocks(source_html)
    current_status = [
        copy.deepcopy(block)
        for block in document.get("blocks", [])
        if isinstance(block, dict)
        and block.get("type") == "callout"
        and _inline_text(block.get("content"))
        .casefold()
        .startswith("editorial status")
    ]
    recovered = {
        **copy.deepcopy(document),
        "blocks": current_status + recovered_blocks,
    }
    return repair_strategic_paper(recovered)


def _site_spawner_opening_blocks() -> list[dict[str, Any]]:
    return [
        {
            "id": "epb-opening-ingress",
            "type": "ingress",
            "content": [
                {
                    "type": "text",
                    "value": (
                        "Wave 10 pays the review debt before it walks "
                        "the prebuilt deployment lane: challenge the "
                        "extractor and ability model, preserve only "
                        "claims that survive execution, then turn the "
                        "remaining evidence into merge order."
                    ),
                }
            ],
        },
        {
            "id": "epb-opening-byline",
            "type": "byline",
            "items": [
                "Independent review",
                "Executed evidence",
                "Decision order",
            ],
        },
        {
            "id": "epb-opening-stats",
            "type": "stats",
            "items": [
                {"value": "4", "label": "ability tiers re-derived"},
                {"value": "2", "label": "inherited premises disproved"},
                {"value": "1", "label": "first-party archive refusal class"},
            ],
        },
    ]


def _site_spawner_wish_as_steps(block: dict[str, Any]) -> dict[str, Any]:
    if block.get("type") == "steps":
        return copy.deepcopy(block)
    if block.get("type") != "callout":
        raise ValueError("c-003 is neither the source callout nor repaired steps")

    original = _normalize(_inline_text(block.get("content")))
    parts = [
        _normalize(part)
        for part in re.split(r"(?=TWO\s+—|Plus:)", original)
        if _normalize(part)
    ]
    if len(parts) != 3 or _normalize(" ".join(parts)) != original:
        raise ValueError("owner wish no longer has its frozen ONE/TWO/Plus shape")

    titles = [
        "Pay the independent review debt",
        "Walk the live prebuilt lane",
        "Finish the admission gate and ledger",
    ]
    return {
        "id": block["id"],
        "type": "steps",
        "steps": [
            {
                "title": title,
                "blocks": [
                    {
                        "type": "paragraph",
                        "content": [{"type": "text", "value": part}],
                    }
                ],
            }
            for title, part in zip(titles, parts)
        ],
    }


def _refine_site_spawner_opening(
    blocks: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    repaired = []
    h1_index = None
    for block in blocks:
        if not isinstance(block, dict):
            repaired.append(copy.deepcopy(block))
            continue
        block_id = block.get("id")
        if block_id in SITE_SPAWNER_OPENING_IDS or (
            block_id == SITE_SPAWNER_WISH_HEADING_ID
        ):
            continue
        if block_id == "c-003":
            repaired.extend(
                [
                    {
                        "id": SITE_SPAWNER_WISH_HEADING_ID,
                        "type": "heading",
                        "level": 2,
                        "text": "The wish, in the owner's own order",
                    },
                    _site_spawner_wish_as_steps(block),
                ]
            )
            continue
        repaired.append(copy.deepcopy(block))
        if (
            h1_index is None
            and block.get("type") == "heading"
            and block.get("level") == 1
        ):
            h1_index = len(repaired) - 1

    if h1_index is None:
        raise ValueError("Paper has no level-one heading")
    repaired[h1_index + 1 : h1_index + 1] = _site_spawner_opening_blocks()
    return repaired


def _site_spawner_is_already_composed(blocks: list[Any]) -> bool:
    top_level = [block for block in blocks if isinstance(block, dict)]
    top_ids = {block.get("id") for block in top_level}
    if not SITE_SPAWNER_OPENING_IDS.issubset(top_ids):
        return False
    if any(block.get("type") == "expandable" for block in top_level):
        return True

    expected = (
        set(SITE_SPAWNER_NOTE_LISTS)
        | SITE_SPAWNER_STEP_LISTS
        | set(SITE_SPAWNER_NOTE_TABLES)
    )
    return expected.issubset(top_ids)


def curate_site_spawner_wave10(document: dict[str, Any]) -> dict[str, Any]:
    if document.get("_id") != SITE_SPAWNER_ID:
        raise ValueError("profile requires {}".format(SITE_SPAWNER_ID))
    revision = document.get("_rev")
    blocks = document.get("blocks")
    if not isinstance(revision, str) or not isinstance(blocks, list):
        raise ValueError("Paper requires a revision and block array")

    if _site_spawner_is_already_composed(blocks):
        repaired = _refine_site_spawner_opening(blocks)
        return {
            "mutations": [
                {
                    "patch": {
                        "id": SITE_SPAWNER_ID,
                        "type": "paper",
                        "set": {"blocks": repaired},
                        "ifRevisionID": revision,
                    }
                },
                {"publish": {"id": SITE_SPAWNER_ID, "type": "paper"}},
            ]
        }

    repaired = []
    h1_seen = False
    source_spacers = 0
    transformed_ids = set()
    for block in blocks:
        if _is_empty_paragraph(block):
            source_spacers += 1
            continue
        if not isinstance(block, dict):
            repaired.append(block)
            continue

        block_id = block.get("id")
        if block_id in SITE_SPAWNER_NOTE_LISTS:
            repaired.append(
                _list_as_notes(block, SITE_SPAWNER_NOTE_LISTS[block_id])
            )
            transformed_ids.add(block_id)
        elif block_id in SITE_SPAWNER_STEP_LISTS:
            repaired.append(_list_as_steps(block))
            transformed_ids.add(block_id)
        elif block_id in SITE_SPAWNER_NOTE_TABLES:
            repaired.append(
                _table_as_notes(block, SITE_SPAWNER_NOTE_TABLES[block_id])
            )
            transformed_ids.add(block_id)
        else:
            repaired.append(copy.deepcopy(block))

        if (
            not h1_seen
            and block.get("type") == "heading"
            and block.get("level") == 1
        ):
            h1_seen = True

    expected_transforms = (
        set(SITE_SPAWNER_NOTE_LISTS)
        | SITE_SPAWNER_STEP_LISTS
        | set(SITE_SPAWNER_NOTE_TABLES)
    )
    if not h1_seen:
        raise ValueError("Paper has no level-one heading")
    if source_spacers != 127:
        raise ValueError(
            "expected 127 frozen spacers, found {}; refusing drift".format(
                source_spacers
            )
        )
    if transformed_ids != expected_transforms:
        missing = sorted(expected_transforms - transformed_ids)
        raise ValueError("frozen editorial targets missing: {}".format(missing))
    if any(_is_empty_paragraph(block) for block in repaired):
        raise AssertionError("repair retained an empty paragraph")
    repaired = _refine_site_spawner_opening(repaired)

    return {
        "mutations": [
            {
                "patch": {
                    "id": SITE_SPAWNER_ID,
                    "type": "paper",
                    "set": {"blocks": repaired},
                    "ifRevisionID": revision,
                }
            },
            {"publish": {"id": SITE_SPAWNER_ID, "type": "paper"}},
        ]
    }


def _text(value: str) -> list[dict[str, str]]:
    return [{"type": "text", "value": value}]


def repair_spacing_doctrine(document: dict[str, Any]) -> dict[str, Any]:
    if document.get("_id") != SPACING_DOCTRINE_ID:
        raise ValueError("profile requires {}".format(SPACING_DOCTRINE_ID))
    revision = document.get("_rev")
    if not isinstance(revision, str):
        raise ValueError("Paper requires a revision")

    title = (
        "The Reader-Owned Spacing Doctrine — rhythm belongs to semantic blocks"
    )
    description = (
        "Vertical rhythm is a shared reader contract, not authored blank content. "
        "Enter creates the next semantic block; Shift+Enter creates a soft break "
        "inside one block. Exact empty paragraphs may remain as unpublished editor "
        "scaffolds, but public, Studio View, email, TUI and CLI/API readers suppress "
        "them and apply one shared cadence between visible semantic blocks."
    )
    blocks = [
        {
            "id": "rsd-eyebrow",
            "type": "eyebrow",
            "text": "BARKPARK PAPERS · REPAIRED DOCTRINE",
        },
        {"id": "rsd-h1", "type": "heading", "level": 1, "text": title},
        {
            "id": "rsd-ingress",
            "type": "ingress",
            "content": _text(
                "A blank paragraph is not meaning. It is editor scaffolding that "
                "became visible because Barkpark once asked content to carry a "
                "reader’s layout job. The repaired law keeps keyboard intent while "
                "making every reader responsible for the same semantic cadence."
            ),
        },
        {
            "id": "rsd-byline",
            "type": "byline",
            "items": [
                "Semantic blocks",
                "Shared cadence",
                "Five-reader parity",
            ],
        },
        {
            "id": "rsd-stats",
            "type": "stats",
            "items": [
                {"value": "351", "label": "blank spacers in 3 canonical Papers"},
                {"value": "127→0", "label": "Site Spawner Wave 10"},
                {"value": "5", "label": "reader contracts"},
            ],
        },
        {
            "id": "rsd-decision",
            "type": "callout",
            "tone": "success",
            "title": "Decision",
            "content": _text(
                "Readers own vertical rhythm between emitted semantic blocks. "
                "Authors own structure, order, emphasis and deliberate inline "
                "breaks. An exact empty paragraph is never published layout."
            ),
        },
        {
            "id": "rsd-h2-failure",
            "type": "heading",
            "level": 2,
            "text": "Why the old doctrine failed",
        },
        {
            "id": "rsd-p-failure",
            "type": "paragraph",
            "content": _text(
                "The old rule treated Enter, Enter as a portable unit of vertical "
                "space. That looked deterministic, but it made layout data "
                "indistinguishable from missing prose. Authors multiplied blank "
                "nodes, public HTML emitted <p></p>, terminal rendering accumulated "
                "blank rows, and long Papers looked hollow even when their evidence "
                "was present."
            ),
        },
        {
            "id": "rsd-notes-failure",
            "type": "notes",
            "items": [
                {
                    "label": "meaning",
                    "lead": "Empty content cannot explain why a gap exists.",
                    "text": "It carries no purpose, hierarchy, provenance or reader value.",
                },
                {
                    "label": "parity",
                    "lead": "One stored blank did not produce one perceptual gap.",
                    "text": "HTML margins, terminal rows, email tables and editor chrome still resolved it differently.",
                },
                {
                    "label": "density",
                    "lead": "Spacer volume hid the real editorial defects.",
                    "text": "Site Spawner Wave 10 had populated lists, but 127 blanks and paragraph-sized bullets made the page feel empty and broken.",
                },
            ],
        },
        {
            "id": "rsd-h2-keyboard",
            "type": "heading",
            "level": 2,
            "text": "The keyboard contract",
        },
        {
            "id": "rsd-table-keyboard",
            "type": "table",
            "head": [_text("gesture"), _text("document meaning"), _text("reader result")],
            "rows": [
                [
                    _text("Shift+Enter"),
                    _text("soft break inside the current semantic block"),
                    _text("the next line, still inside that block"),
                ],
                [
                    _text("Enter"),
                    _text("finish this block and begin the next block"),
                    _text("shared cadence between two visible blocks"),
                ],
                [
                    _text("Enter, Enter"),
                    _text("an editable empty scaffold before the next block"),
                    _text("no published visual content"),
                ],
                [
                    _text("Section / divider / typed layout block"),
                    _text("an intentional structural transition"),
                    _text("the block’s explicit semantic treatment"),
                ],
            ],
        },
        {
            "id": "rsd-h2-invariant",
            "type": "heading",
            "level": 2,
            "text": "The invariant",
        },
        {
            "id": "rsd-steps-invariant",
            "type": "steps",
            "steps": [
                {
                    "title": "Compose preserves authoring intent.",
                    "blocks": [
                        {
                            "type": "paragraph",
                            "content": _text(
                                "A fresh editor may carry an exact empty PdParagraph "
                                "while the author is composing."
                            ),
                        }
                    ],
                },
                {
                    "title": "Published readers emit only visible semantic groups.",
                    "blocks": [
                        {
                            "type": "paragraph",
                            "content": _text(
                                "Public HTML, Studio View, email, TUI and CLI/API "
                                "skip zero-content paragraph groups."
                            ),
                        }
                    ],
                },
                {
                    "title": "Cadence is inserted between emitted groups.",
                    "blocks": [
                        {
                            "type": "paragraph",
                            "content": _text(
                                "The renderer never derives spacing from the raw "
                                "array index, so skipped scaffolds cannot add gaps."
                            ),
                        }
                    ],
                },
                {
                    "title": "Non-empty paragraphs remain byte-faithful.",
                    "blocks": [
                        {
                            "type": "paragraph",
                            "content": _text(
                                "Suppression is exact and narrow: authored text, "
                                "marks, links and soft breaks are unchanged."
                            ),
                        }
                    ],
                },
            ],
        },
        {
            "id": "rsd-h2-proof",
            "type": "heading",
            "level": 2,
            "text": "What proves the repair",
        },
        {
            "id": "rsd-notes-proof",
            "type": "notes",
            "items": [
                {
                    "label": "reference",
                    "lead": "criminality-constraint-frontiers-draft scores 100.",
                    "text": "It uses zero empty spacers and earns rhythm through semantic hierarchy.",
                },
                {
                    "label": "case",
                    "lead": "Site Spawner Wave 10 moved from 224 to 100 blocks.",
                    "text": "All 127 blanks were removed, dense lists became notes, and the factual evidence remained.",
                },
                {
                    "label": "tests",
                    "lead": "1,128 Phoenix/PortableDoc tests pass.",
                    "text": "The full Go terminal suite and deterministic Python structure/quality suites pass too.",
                },
                {
                    "label": "reader",
                    "lead": "The opening and endgame are visible in standalone and TUI captures.",
                    "text": "The final seal still requires revision-pinned email, Studio and CLI/API evidence after deploy.",
                },
            ],
        },
        {
            "id": "rsd-h2-migration",
            "type": "heading",
            "level": 2,
            "text": "How existing Papers migrate",
        },
        {
            "id": "rsd-steps-migration",
            "type": "steps",
            "steps": [
                {
                    "title": "Freeze the Paper id and revision.",
                    "blocks": [
                        {
                            "type": "paragraph",
                            "content": _text(
                                "Every repair is optimistic-lock guarded; a changed "
                                "revision stops the mutation."
                            ),
                        }
                    ],
                },
                {
                    "title": "Remove only exact empty paragraph scaffolds.",
                    "blocks": [
                        {
                            "type": "paragraph",
                            "content": _text(
                                "No prose, marks, tables, evidence or authored soft "
                                "breaks are deleted."
                            ),
                        }
                    ],
                },
                {
                    "title": "Repair the composition the blanks were hiding.",
                    "blocks": [
                        {
                            "type": "paragraph",
                            "content": _text(
                                "Add an editorial opening; reframe prose-sized "
                                "bullets and oversized prose tables where meaning "
                                "requires it."
                            ),
                        }
                    ],
                },
                {
                    "title": "Capture every declared reader at the repaired revision.",
                    "blocks": [
                        {
                            "type": "paragraph",
                            "content": _text(
                                "A Paper passes only when its public, Studio, TUI, "
                                "email and CLI/API evidence is current."
                            ),
                        }
                    ],
                },
            ],
        },
        {
            "id": "rsd-final",
            "type": "callout",
            "tone": "info",
            "title": "The doctrine in one line",
            "content": _text(
                "Store meaning; render rhythm. Empty editor scaffolds stay editable "
                "and disappear from every published reader."
            ),
        },
    ]

    return {
        "mutations": [
            {
                "patch": {
                    "id": SPACING_DOCTRINE_ID,
                    "type": "paper",
                    "ifRevisionID": revision,
                    "set": {
                        "title": title,
                        "description": description,
                        "blocks": blocks,
                        "tags": [
                            {
                                "tag": "portabledoc",
                                "strength": 96,
                                "rationale": "defines the cross-reader rhythm contract",
                            },
                            {
                                "tag": "doctrine",
                                "strength": 92,
                                "rationale": "replaces spacer-content law with semantic cadence",
                            },
                            {
                                "tag": "cssom-parity",
                                "strength": 78,
                                "rationale": "one shared surface law across public and Studio readers",
                            },
                            {
                                "tag": "authoring-excellence",
                                "strength": 72,
                                "rationale": "keeps keyboard intent without publishing blank content",
                            },
                        ],
                    },
                }
            },
            {"publish": {"id": SPACING_DOCTRINE_ID, "type": "paper"}},
        ]
    }


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument(
        "--profile",
        required=True,
        choices=(
            "site-spawner-wave-10",
            "mechanical-spacing-doctrine",
            "canonical-epic",
            "strategic-paper",
        ),
    )
    parser.add_argument(
        "--source-html",
        help=(
            "Immutable legacy HTML snapshot to recover before strategic repair; "
            "valid only with --profile strategic-paper"
        ),
    )
    args = parser.parse_args(argv)
    if args.source_html and args.profile != "strategic-paper":
        parser.error("--source-html requires --profile strategic-paper")

    document = json.loads(Path(args.input).read_text(encoding="utf-8"))
    if args.profile == "site-spawner-wave-10":
        mutation = curate_site_spawner_wave10(document)
    elif args.profile == "mechanical-spacing-doctrine":
        mutation = repair_spacing_doctrine(document)
    elif args.profile == "strategic-paper":
        if args.source_html:
            mutation = repair_strategic_paper_from_html(
                document,
                Path(args.source_html).read_text(encoding="utf-8"),
            )
        else:
            mutation = repair_strategic_paper(document)
    else:
        mutation = repair_canonical_epic(document)
    json.dump(mutation, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
