#!/usr/bin/env python3
"""Score Paper editorial quality without rewarding ornamental block volume."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Iterator, Optional


SCHEMA = "barkpark.paper-quality.v1"
REQUIRED_READERS = ("public", "studio", "tui80", "email", "cli_api")
OPENING_WINDOW = 8
ORIENTATION_TYPES = {"byline", "stats", "toc", "list", "steps"}
MAX_PRIMARY_WORDS = 5_000
MAX_TOP_LEVEL_BLOCKS = 80
MAX_TOP_LEVEL_HEADINGS = 16
MAX_STEP_TITLE_WORDS = 16
MAX_PRIMARY_PARAGRAPH_WORDS = 140
MAX_PRIMARY_NOTE_ITEM_WORDS = 80
MAX_PRIMARY_TABLE_CELL_WORDS = 60
TEXT_KEYS = {
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
}
NESTED_BLOCK_KEYS = {
    "blocks",
    "children",
    "columns",
    "content",
    "items",
    "panels",
    "rows",
    "sections",
    "steps",
    "tabs",
}


def _plain_text(value: Any) -> str:
    """Extract reader-visible prose while ignoring ids, types, and metadata."""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        return " ".join(filter(None, (_plain_text(item) for item in value)))
    if not isinstance(value, dict):
        return ""

    parts = []
    for key, child in value.items():
        if key in TEXT_KEYS:
            rendered = _plain_text(child)
            if rendered:
                parts.append(rendered)
    return " ".join(parts)


def _word_count(value: Any) -> int:
    return len(_plain_text(value).split())


def _empty_paragraph(block: Any) -> bool:
    if not isinstance(block, dict) or block.get("type") != "paragraph":
        return False
    content = block.get("content")
    text = block.get("text")
    return content in (None, []) and not (
        isinstance(text, str) and bool(text.strip())
    )


def _walk_dicts(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for key, child in value.items():
            if key in NESTED_BLOCK_KEYS:
                yield from _walk_dicts(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_dicts(child)


def _first_pass_blocks(blocks: list[Any]) -> list[Any]:
    """Return what a standalone reader must absorb before opening disclosure UI."""
    return [
        block
        for block in blocks
        if not (
            isinstance(block, dict)
            and block.get("type") == "expandable"
            and block.get("open") is not True
        )
    ]


def _meaningful(block: Any) -> bool:
    if not isinstance(block, dict) or _empty_paragraph(block):
        return False
    if _plain_text(block):
        return True
    block_type = block.get("type")
    return block_type in {
        "audio",
        "callout",
        "code",
        "divider",
        "embed",
        "figure",
        "gallery",
        "image",
        "quote",
        "sheet",
        "video",
    }


def _tag_names(document: dict[str, Any]) -> set[str]:
    names = set()
    for tag in document.get("tags", []):
        if isinstance(tag, str):
            names.add(tag)
        elif isinstance(tag, dict) and isinstance(tag.get("tag"), str):
            names.add(tag["tag"])
    return names


def _append_unique(values: list[str], value: str) -> None:
    if value not in values:
        values.append(value)


def _outline_failures(blocks: list[Any]) -> list[str]:
    headings = [
        block
        for block in blocks
        if isinstance(block, dict) and block.get("type") == "heading"
    ]
    levels = [
        block.get("level")
        for block in headings
        if isinstance(block.get("level"), int)
    ]
    failures = []
    if levels.count(1) != 1:
        failures.append("outline_requires_one_h1")
    if any(current > previous + 1 for previous, current in zip(levels, levels[1:])):
        failures.append("outline_heading_level_jump")
    return failures


def _density_warnings(blocks: list[Any]) -> tuple[list[str], dict[str, int]]:
    warnings: list[str] = []
    longest_list_item_words = 0
    largest_table_rows = 0
    longest_primary_paragraph_words = 0
    longest_primary_note_item_words = 0
    longest_primary_table_cell_words = 0

    for block in _walk_dicts(blocks):
        if block.get("type") == "list":
            items = block.get("items", [])
            if isinstance(items, list):
                longest_list_item_words = max(
                    [longest_list_item_words]
                    + [_word_count(item) for item in items]
                )
        if block.get("type") == "table":
            rows = block.get("rows", [])
            if isinstance(rows, list):
                largest_table_rows = max(largest_table_rows, len(rows))

    for block in _walk_dicts(_first_pass_blocks(blocks)):
        block_type = block.get("type")
        if block_type == "paragraph":
            longest_primary_paragraph_words = max(
                longest_primary_paragraph_words,
                _word_count(block),
            )
        elif block_type == "notes":
            items = block.get("items", [])
            if isinstance(items, list):
                longest_primary_note_item_words = max(
                    [longest_primary_note_item_words]
                    + [_word_count(item) for item in items]
                )
        elif block_type == "table":
            rows = block.get("rows", [])
            if isinstance(rows, list):
                longest_primary_table_cell_words = max(
                    [longest_primary_table_cell_words]
                    + [
                        _word_count(cell)
                        for row in rows
                        if isinstance(row, list)
                        for cell in row
                    ]
                )

    if longest_list_item_words > 40:
        warnings.append("paragraph_sized_list_item")
    if largest_table_rows > 12:
        warnings.append("oversized_table")
    if longest_primary_paragraph_words > MAX_PRIMARY_PARAGRAPH_WORDS:
        warnings.append("overloaded_primary_paragraph")
    if longest_primary_note_item_words > MAX_PRIMARY_NOTE_ITEM_WORDS:
        warnings.append("overloaded_primary_note_item")
    if longest_primary_table_cell_words > MAX_PRIMARY_TABLE_CELL_WORDS:
        warnings.append("overloaded_primary_table_cell")

    return warnings, {
        "longest_list_item_words": longest_list_item_words,
        "largest_table_rows": largest_table_rows,
        "longest_primary_paragraph_words": longest_primary_paragraph_words,
        "longest_primary_note_item_words": longest_primary_note_item_words,
        "longest_primary_table_cell_words": longest_primary_table_cell_words,
    }


def _composition_failures(blocks: list[Any]) -> tuple[list[str], dict[str, int]]:
    failures: list[str] = []
    first_pass = _first_pass_blocks(blocks)
    primary_words = _word_count(first_pass)
    top_level_headings = sum(
        1
        for block in blocks
        if isinstance(block, dict) and block.get("type") == "heading"
    )
    empty_step_bodies = 0
    overloaded_step_titles = 0
    headerless_tables = 0
    block_ids = []
    appendix_numbers = []

    for block in _walk_dicts(blocks):
        block_type = block.get("type")
        block_id = block.get("id")
        if isinstance(block_type, str) and isinstance(block_id, str) and block_id:
            block_ids.append(block_id)
        if block_type == "expandable":
            match = re.match(
                r"^Evidence appendix (\d+)\b",
                str(block.get("summary") or "").strip(),
            )
            if match:
                appendix_numbers.append(int(match.group(1)))
        if block_type == "steps":
            steps = block.get("steps", [])
            if isinstance(steps, list):
                for step in steps:
                    if not isinstance(step, dict):
                        continue
                    children = step.get("blocks")
                    title_words = _word_count(step.get("title", ""))
                    if (
                        title_words == 0
                        or (
                            title_words > MAX_STEP_TITLE_WORDS
                            and (
                                not isinstance(children, list)
                                or not any(_meaningful(child) for child in children)
                            )
                        )
                    ):
                        empty_step_bodies += 1
                    if title_words > MAX_STEP_TITLE_WORDS:
                        overloaded_step_titles += 1
        elif block_type == "table":
            rows = block.get("rows")
            head = block.get("head")
            if (
                isinstance(rows, list)
                and rows
                and (not isinstance(head, list) or not head)
            ):
                headerless_tables += 1

    if primary_words > MAX_PRIMARY_WORDS:
        failures.append("primary_reading_load_exceeded")
    if len(blocks) > MAX_TOP_LEVEL_BLOCKS:
        failures.append("top_level_block_overload")
    if top_level_headings > MAX_TOP_LEVEL_HEADINGS:
        failures.append("top_level_heading_overload")
    if empty_step_bodies:
        failures.append("empty_step_body")
    if overloaded_step_titles:
        failures.append("overloaded_step_title")
    if headerless_tables:
        failures.append("table_missing_header")
    if len(block_ids) != len(set(block_ids)):
        failures.append("duplicate_block_id")
    if appendix_numbers and appendix_numbers != list(
        range(1, len(appendix_numbers) + 1)
    ):
        failures.append("evidence_appendix_numbering")

    return failures, {
        "primary_visible_words": primary_words,
        "top_level_headings": top_level_headings,
        "empty_step_bodies": empty_step_bodies,
        "overloaded_step_titles": overloaded_step_titles,
        "headerless_tables": headerless_tables,
        "duplicate_block_ids": len(block_ids) - len(set(block_ids)),
        "evidence_appendices": len(appendix_numbers),
    }


def _reader_failures(
    paper_id: str,
    revision: Any,
    reader_evidence: Optional[dict[str, Any]],
    *,
    require_content_proof: bool,
) -> list[str]:
    evidence = (reader_evidence or {}).get(paper_id)
    if not isinstance(evidence, dict):
        return ["reader_evidence_missing"]
    if evidence.get("revision") != revision:
        return ["reader_evidence_revision_mismatch"]

    readers = evidence.get("readers")
    if not isinstance(readers, dict):
        return ["reader_evidence_missing"]

    failures = []
    expected_hash = evidence.get("semantic_text_sha256")
    if require_content_proof and (
        not isinstance(expected_hash, str)
        or re.fullmatch(r"[0-9a-f]{64}", expected_hash) is None
    ):
        failures.append("reader_content_proof_missing")

    for reader in REQUIRED_READERS:
        reader_record = readers.get(reader)
        status = (
            reader_record.get("status")
            if isinstance(reader_record, dict)
            else reader_record
        )
        if status not in ("pass", True):
            failures.append(
                "reader_{}_{}".format(
                    reader, "missing" if status is None else "failed"
                )
            )
            continue
        if require_content_proof:
            if not isinstance(reader_record, dict) or not isinstance(
                reader_record.get("semantic_text_sha256"), str
            ):
                failures.append(
                    "reader_{}_content_proof_missing".format(reader)
                )
            elif reader_record["semantic_text_sha256"] != expected_hash:
                failures.append(
                    "reader_{}_content_proof_mismatch".format(reader)
                )
    return failures


def _audit_one(
    document: dict[str, Any],
    *,
    reader_evidence: Optional[dict[str, Any]],
    require_reader_evidence: bool,
    require_reader_content_proof: bool,
) -> dict[str, Any]:
    paper_id = str(document.get("_id") or document.get("id") or "")
    revision = document.get("_rev") or document.get("revision")
    raw_blocks = document.get("blocks")
    blocks = raw_blocks if isinstance(raw_blocks, list) else []
    meaningful = [block for block in blocks if _meaningful(block)]
    visible_words = _word_count(blocks)
    empty_spacers = sum(1 for block in _walk_dicts(blocks) if _empty_paragraph(block))

    hard_failures: list[str] = []
    if not meaningful or visible_words == 0:
        hard_failures.append("hollow")
    elif len(meaningful) < 3:
        hard_failures.append("micro_only")
    if not isinstance(raw_blocks, list):
        hard_failures.append("blocks_not_array")
    if empty_spacers:
        hard_failures.append("empty_paragraph_spacer")

    opening = meaningful[:OPENING_WINDOW]
    opening_types = {
        block.get("type") for block in opening if isinstance(block, dict)
    }
    if not any(
        isinstance(block, dict)
        and block.get("type") == "heading"
        and block.get("level") == 1
        for block in opening
    ):
        hard_failures.append("opening_missing_h1")
    if "ingress" not in opening_types:
        hard_failures.append("opening_missing_ingress")
    if not opening_types.intersection(ORIENTATION_TYPES):
        hard_failures.append("opening_missing_orientation")

    for failure in _outline_failures(blocks):
        _append_unique(hard_failures, failure)

    composition_failures, composition_metrics = _composition_failures(blocks)
    for failure in composition_failures:
        _append_unique(hard_failures, failure)

    if require_reader_evidence or require_reader_content_proof:
        for failure in _reader_failures(
            paper_id,
            revision,
            reader_evidence,
            require_content_proof=require_reader_content_proof,
        ):
            _append_unique(hard_failures, failure)

    warnings, density_metrics = _density_warnings(blocks)
    hard_failures = sorted(hard_failures)
    warnings = sorted(warnings)
    score = max(0, 100 - (20 * len(hard_failures)) - (5 * len(warnings)))

    block_types = Counter(
        str(block.get("type"))
        for block in _walk_dicts(blocks)
        if isinstance(block.get("type"), str)
    )
    return {
        "paper_id": paper_id,
        "revision": revision,
        "score": score,
        "pass": not hard_failures,
        "hard_failures": hard_failures,
        "warnings": warnings,
        "metrics": {
            "top_level_blocks": len(blocks),
            "meaningful_top_level_blocks": len(meaningful),
            "visible_words": visible_words,
            "empty_paragraph_spacers": empty_spacers,
            "block_types": dict(sorted(block_types.items())),
            **density_metrics,
            **composition_metrics,
        },
    }


def audit_papers(
    documents: Iterable[dict[str, Any]],
    *,
    reader_evidence: Optional[dict[str, Any]] = None,
    require_reader_evidence: bool = False,
    require_reader_content_proof: bool = False,
) -> dict[str, Any]:
    """Return a stable cohort report whose pass state is defined by hard gates."""
    papers = sorted(
        (
            _audit_one(
                document,
                reader_evidence=reader_evidence,
                require_reader_evidence=require_reader_evidence,
                require_reader_content_proof=require_reader_content_proof,
            )
            for document in documents
            if isinstance(document, dict)
        ),
        key=lambda paper: paper["paper_id"],
    )
    hard_counts = Counter(
        failure for paper in papers for failure in paper["hard_failures"]
    )
    warning_counts = Counter(
        warning for paper in papers for warning in paper["warnings"]
    )
    passed = sum(1 for paper in papers if paper["pass"])
    return {
        "schema": SCHEMA,
        "pass": bool(papers) and passed == len(papers),
        "papers_scanned": len(papers),
        "papers_passed": passed,
        "papers_failed": len(papers) - passed,
        "hard_failure_counts": dict(sorted(hard_counts.items())),
        "warning_counts": dict(sorted(warning_counts.items())),
        "papers": papers,
    }


def _documents(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        if isinstance(payload.get("documents"), list):
            return [
                item
                for item in payload["documents"]
                if isinstance(item, dict)
            ]
        if isinstance(payload.get("results"), list):
            return [
                item for item in payload["results"] if isinstance(item, dict)
            ]
        return [payload]
    raise ValueError("input must be a Paper object, array, or documents/results envelope")


def _load_json(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Paper JSON path, or - for stdin")
    parser.add_argument("--reader-evidence", help="Revision-pinned reader evidence JSON")
    parser.add_argument("--require-reader-evidence", action="store_true")
    parser.add_argument(
        "--require-reader-content-proof",
        action="store_true",
        help=(
            "Require each reader record to carry the revision-pinned canonical "
            "semantic-text SHA-256, not only a pass status."
        ),
    )
    parser.add_argument("--require-tag", help="Audit only Papers carrying this exact tag")
    parser.add_argument("--summary-only", action="store_true")
    args = parser.parse_args(argv)

    documents = _documents(_load_json(args.input))
    if args.require_tag:
        documents = [
            document
            for document in documents
            if args.require_tag in _tag_names(document)
        ]
    evidence = _load_json(args.reader_evidence) if args.reader_evidence else None
    report = audit_papers(
        documents,
        reader_evidence=evidence,
        require_reader_evidence=args.require_reader_evidence,
        require_reader_content_proof=args.require_reader_content_proof,
    )
    if args.summary_only:
        report = {key: value for key, value in report.items() if key != "papers"}
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
