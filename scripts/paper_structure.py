#!/usr/bin/env python3
"""Audit persisted Paper blocks for shapes that readers cannot render faithfully."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Iterator


def _text_present(value: Any) -> bool:
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, list):
        return any(_text_present(item) for item in value)
    if isinstance(value, dict):
        return any(_text_present(item) for item in value.values())
    return False


def _empty_paragraph(block: Any) -> bool:
    if not isinstance(block, dict) or block.get("type") != "paragraph":
        return False
    content = block.get("content")
    text = block.get("text")
    return content in (None, []) and not (
        isinstance(text, str) and bool(text.strip())
    )


def _violation(
    document: dict[str, Any],
    path: str,
    kind: str,
    *,
    safe: bool,
    detail: str,
) -> dict[str, Any]:
    return {
        "paper_id": document.get("_id"),
        "revision": document.get("_rev"),
        "path": path,
        "kind": kind,
        "safe_repair": safe,
        "detail": detail,
    }


def audit_blocks(
    document: dict[str, Any],
    blocks: Any,
    prefix: str = "blocks",
    *,
    _seen_ids: dict[str, str] | None = None,
    _seen_appendix_numbers: dict[int, str] | None = None,
) -> list[dict[str, Any]]:
    """Return deterministic, path-addressed structural violations."""
    if _seen_ids is None:
        _seen_ids = {}
    if _seen_appendix_numbers is None:
        _seen_appendix_numbers = {}
    if not isinstance(blocks, list):
        return [
            _violation(
                document,
                prefix,
                "blocks_not_array",
                safe=False,
                detail="Paper blocks must be an array.",
            )
        ]

    findings: list[dict[str, Any]] = []
    for block_index, block in enumerate(blocks):
        block_path = f"{prefix}[{block_index}]"
        if not isinstance(block, dict):
            findings.append(
                _violation(
                    document,
                    block_path,
                    "block_not_object",
                    safe=False,
                    detail="A block must be an object.",
                )
            )
            continue

        block_type = block.get("type")
        block_token = _type_token(block)
        block_id = block.get("id")
        if isinstance(block_id, str) and block_id:
            if block_id in _seen_ids:
                findings.append(
                    _violation(
                        document,
                        block_path,
                        "duplicate_block_id",
                        safe=False,
                        detail=(
                            "Block ids must be unique across the complete Paper; "
                            f"first seen at {_seen_ids[block_id]}."
                        ),
                    )
                )
            else:
                _seen_ids[block_id] = block_path

        if block_type == "expandable":
            summary = str(block.get("summary") or "").strip()
            match = re.match(r"^Evidence appendix (\d+)\b", summary)
            if match:
                number = int(match.group(1))
                if number in _seen_appendix_numbers:
                    findings.append(
                        _violation(
                            document,
                            f"{block_path}.summary",
                            "evidence_appendix_number_duplicate",
                            safe=False,
                            detail=(
                                "Evidence appendix numbers must be unique; "
                                f"first seen at {_seen_appendix_numbers[number]}."
                            ),
                        )
                    )
                else:
                    _seen_appendix_numbers[number] = f"{block_path}.summary"

        if _empty_paragraph(block):
            findings.append(
                _violation(
                    document,
                    block_path,
                    "empty_paragraph_spacer",
                    safe=True,
                    detail=(
                        "Empty paragraphs are editor scaffolds, not published layout; "
                        "readers own section rhythm."
                    ),
                )
            )

        if block_token in {"list", "bulletlist", "orderedlist"}:
            list_dialect = block_type != "list" or not isinstance(
                block.get("items"), list
            )
            if list_dialect:
                try:
                    _normalize_list_dialect(block)
                    safe = True
                except (TypeError, ValueError):
                    safe = False
                findings.append(
                    _violation(
                        document,
                        block_path,
                        (
                            "list_alias_dialect"
                            if block_type != "list"
                            else "list_content_dialect"
                        ),
                        safe=safe,
                        detail=(
                            "This populated collection uses a legacy list type or item "
                            "carrier; canonical readers consume type=list with items."
                        ),
                    )
                )

            items = block.get("items", [])
            if list_dialect:
                continue
            if not isinstance(items, list):
                findings.append(
                    _violation(
                        document,
                        f"{block_path}.items",
                        "list_items_not_array",
                        safe=False,
                        detail="List items must be an array.",
                    )
                )
            else:
                for item_index, item in enumerate(items):
                    item_path = f"{block_path}.items[{item_index}]"
                    if isinstance(item, dict):
                        # Item ids are stable authoring metadata on the accepted
                        # object form. Every reader consumes content/text while
                        # preserving the wrapper on round-trip.
                        if (
                            set(item).issubset({"id", "content", "text"})
                            and isinstance(item.get("id"), str)
                            and (
                                isinstance(item.get("content"), list)
                                or isinstance(item.get("text"), str)
                            )
                        ):
                            continue
                        content = item.get("content")
                        text = item.get("text")
                        recognized = set(item).issubset({"content", "text"})
                        safe = recognized and (
                            isinstance(content, list) or isinstance(text, str)
                        )
                        findings.append(
                            _violation(
                                document,
                                item_path,
                                "list_item_object_wrapper",
                                safe=safe,
                                detail=(
                                    "Readers disagree on object-wrapped list items; "
                                    "canonical items are inline arrays."
                                ),
                            )
                        )
                    elif not isinstance(item, list):
                        scalar = item is None or isinstance(
                            item, (str, int, float, bool)
                        )
                        findings.append(
                            _violation(
                                document,
                                item_path,
                                "list_item_scalar",
                                safe=scalar,
                                detail=(
                                    "Canonical list items are inline arrays; "
                                    "supported scalar items must be normalized "
                                    "before publish."
                                ),
                            )
                        )

        if block_token == "table":
            rows = block.get("rows", [])
            table_dialect = not isinstance(block.get("rows"), list)
            if table_dialect:
                try:
                    _normalize_table_content_dialect(block)
                    safe = True
                except (TypeError, ValueError):
                    safe = False
                findings.append(
                    _violation(
                        document,
                        block_path,
                        "table_content_dialect",
                        safe=safe,
                        detail=(
                            "This populated table stores headers/rows under a legacy "
                            "content carrier; canonical readers consume head/rows."
                        ),
                    )
                )
                continue
            columns = block.get("columns")
            if isinstance(columns, list):
                for column_index, column in enumerate(columns):
                    if (
                        isinstance(column, dict)
                        and set(column).issubset({"text"})
                        and isinstance(column.get("text"), str)
                    ):
                        findings.append(
                            _violation(
                                document,
                                f"{block_path}.columns[{column_index}]",
                                "table_column_text_wrapper",
                                safe=True,
                                detail=(
                                    "Text-only table columns are legacy header cells; "
                                    "canonical headers live in block.head."
                                ),
                            )
                        )
            column_keys = (
                [column.get("key") for column in columns]
                if isinstance(columns, list)
                and all(isinstance(column, dict) for column in columns)
                else []
            )
            record_table = (
                bool(column_keys)
                and all(isinstance(key, str) and key for key in column_keys)
                and len(set(column_keys)) == len(column_keys)
                and all(
                    column.get("label") is None
                    or isinstance(column.get("label"), str)
                    for column in columns
                )
            )
            if not isinstance(rows, list):
                findings.append(
                    _violation(
                        document,
                        f"{block_path}.rows",
                        "table_rows_not_array",
                        safe=False,
                        detail="Table rows must be an array.",
                    )
                )
            else:
                for row_index, row in enumerate(rows):
                    row_path = f"{block_path}.rows[{row_index}]"
                    if isinstance(row, dict):
                        cells = row.get("cells")
                        is_record_row = (
                            record_table
                            and set(row).issubset(column_keys)
                            and all(_record_scalar(value) for value in row.values())
                        )
                        recognized = set(row).issubset({"cells", "header"})
                        safe = is_record_row or (
                            recognized and isinstance(cells, list)
                        )
                        findings.append(
                            _violation(
                                document,
                                row_path,
                                (
                                    "table_record_row"
                                    if is_record_row
                                    else "table_row_object_wrapper"
                                ),
                                safe=safe,
                                detail=(
                                    "Readers expect each table row to be a cell array; "
                                    "an object wrapper renders as an empty cell."
                                ),
                            )
                        )
                        if row.get("header") is True:
                            findings.append(
                                _violation(
                                    document,
                                    f"{row_path}.header",
                                    "table_row_header_marker",
                                    safe=safe and row_index == 0,
                                    detail=(
                                        "Canonical table headers live in block.head, "
                                        "not on a row object."
                                    ),
                                )
                            )
                        cells_to_check = [] if is_record_row else cells
                    else:
                        cells_to_check = row

                    if isinstance(cells_to_check, list):
                        for cell_index, cell in enumerate(cells_to_check):
                            if isinstance(cell, dict):
                                content_wrapper = (
                                    "content" in cell
                                    and set(cell).issubset({"content", "header"})
                                    and isinstance(cell.get("content"), list)
                                )
                                text_wrapper = (
                                    "text" in cell
                                    and set(cell).issubset({"text", "header"})
                                    and isinstance(cell.get("text"), str)
                                )
                                safe = content_wrapper or text_wrapper
                                findings.append(
                                    _violation(
                                        document,
                                        f"{row_path}.cells[{cell_index}]",
                                        (
                                            "table_cell_object_wrapper"
                                            if content_wrapper
                                            else "table_cell_text_wrapper"
                                            if text_wrapper
                                            else "table_cell_unrenderable"
                                        ),
                                        safe=safe,
                                        detail=(
                                            "Table cells must be inline arrays or "
                                            "content wrappers understood by every reader."
                                        ),
                                    )
                                )

        if (
            block_type == "callout"
            and _text_present(block.get("text"))
            and not _text_present(block.get("content"))
            and not _text_present(block.get("slots"))
        ):
            safe = isinstance(block.get("text"), str) and "content" not in block
            findings.append(
                _violation(
                    document,
                    f"{block_path}.text",
                    "callout_text_stranded",
                    safe=safe,
                    detail=(
                        "Callout readers consume content/slots; prose under text "
                        "is silently invisible."
                    ),
                )
            )

        for child_key in ("blocks", "children"):
            children = block.get(child_key)
            if isinstance(children, list):
                findings.extend(
                    audit_blocks(
                        document,
                        children,
                        prefix=f"{block_path}.{child_key}",
                        _seen_ids=_seen_ids,
                        _seen_appendix_numbers=_seen_appendix_numbers,
                    )
                )

    return findings


def _text_node(value: Any) -> list[dict[str, Any]]:
    return [{"type": "text", "value": "" if value is None else str(value)}]


def _record_scalar(value: Any) -> bool:
    return value is None or isinstance(value, (str, int, float, bool))


def _flatten_cell(content: list[Any]) -> list[Any]:
    flattened: list[Any] = []
    for node in content:
        if (
            isinstance(node, dict)
            and node.get("type") == "paragraph"
            and isinstance(node.get("content"), list)
        ):
            flattened.extend(node["content"])
        else:
            flattened.append(node)
    return flattened


def _canonical_cell(cell: Any, *, header: bool = False) -> Any:
    if _record_scalar(cell):
        return _text_node(cell)
    if isinstance(cell, list):
        return _flatten_cell(cell)
    if not isinstance(cell, dict):
        return cell
    allowed = {"content", "text", "header"} if header else {"content", "text"}
    if set(cell).issubset(allowed):
        if isinstance(cell.get("content"), list):
            return _flatten_cell(cell["content"])
        if isinstance(cell.get("text"), str):
            return _text_node(cell["text"])
    return cell


def _type_token(value: Any) -> str:
    if not isinstance(value, dict):
        return ""
    return (
        str(value.get("type") or "")
        .replace("_", "")
        .replace("-", "")
        .lower()
    )


def _canonical_inline(value: Any) -> Any:
    if value is None:
        return []
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
        except json.JSONDecodeError:
            decoded = None
        if isinstance(decoded, (dict, list)):
            return _canonical_inline(decoded)
        return _text_node(value)
    if _record_scalar(value):
        return _text_node(value)
    if isinstance(value, list):
        flattened: list[Any] = []
        for child in value:
            canonical = _canonical_inline(child)
            if not isinstance(canonical, list):
                raise ValueError("inline child is not losslessly recognizable")
            flattened.extend(canonical)
        return flattened
    if not isinstance(value, dict):
        return value
    value_type = _type_token(value)
    if value_type == "text" and isinstance(value.get("value"), str):
        node = copy.deepcopy(value)
        node.pop("text", None)
        return [node]
    if set(value).issubset({"content", "text"}):
        if isinstance(value.get("content"), list):
            return _canonical_inline(value["content"])
        if isinstance(value.get("text"), str):
            return _text_node(value["text"])
    if isinstance(value.get("content"), list) and value_type in {
        "listitem",
        "paragraph",
        "tablecell",
        "tableheader",
    }:
        return _canonical_inline(value["content"])
    if isinstance(value.get("type"), str) and value["type"]:
        return [copy.deepcopy(value)]
    if isinstance(value.get("text"), str):
        return _text_node(value["text"])
    return copy.deepcopy(value)


def _list_source(block: dict[str, Any]) -> list[Any]:
    for key in ("items", "content", "children"):
        source = block.get(key)
        if isinstance(source, list):
            return source
    raise ValueError("list block has no lossless item carrier")


def _canonical_list_item(item: Any) -> Any:
    if (
        isinstance(item, dict)
        and isinstance(item.get("id"), str)
        and set(item).issubset({"id", "content", "text"})
        and (
            isinstance(item.get("content"), list)
            or isinstance(item.get("text"), str)
        )
    ):
        return copy.deepcopy(item)
    return _canonical_inline(item)


def _normalize_list_dialect(block: dict[str, Any]) -> dict[str, Any]:
    source_type = _type_token(block)
    items = [_canonical_list_item(item) for item in _list_source(block)]
    if not all(
        isinstance(item, list)
        or (
            isinstance(item, dict)
            and isinstance(item.get("id"), str)
            and set(item).issubset({"id", "content", "text"})
        )
        for item in items
    ):
        raise ValueError("list item is not losslessly canonicalizable")
    style = str(block.get("style") or block.get("listStyle") or "").lower()
    ordered = (
        block.get("ordered") is True
        or source_type == "orderedlist"
        or style in {"ordered", "number", "numbered", "decimal"}
    )
    normalized = {
        key: copy.deepcopy(value)
        for key, value in block.items()
        if key not in {"content", "children", "items", "style", "listStyle"}
    }
    normalized.update({"type": "list", "ordered": ordered, "items": items})
    return normalized


def _table_row_cells(row: Any) -> tuple[list[Any], bool]:
    if isinstance(row, list):
        return row, False
    if not isinstance(row, dict):
        raise ValueError("table row is not losslessly recognizable")
    cells = row.get("content") if isinstance(row.get("content"), list) else row.get("cells")
    if not isinstance(cells, list):
        raise ValueError("table row has no lossless cell carrier")
    header_flags = [
        isinstance(cell, dict)
        and (cell.get("header") is True or _type_token(cell) == "tableheader")
        for cell in cells
    ]
    return cells, row.get("header") is True or (bool(cells) and all(header_flags))


def _normalize_table_content_dialect(block: dict[str, Any]) -> dict[str, Any]:
    source = block.get("content")
    explicit_head = None
    if isinstance(source, dict):
        explicit_head = source.get("head") or source.get("header")
        source_rows = source.get("rows")
    elif isinstance(source, list):
        source_rows = source
    else:
        raise ValueError("table block has no lossless row carrier")
    if not isinstance(source_rows, list):
        raise ValueError("table content rows are not an array")

    rows: list[list[Any]] = []
    row_headers: list[bool] = []
    for row in source_rows:
        cells, header = _table_row_cells(row)
        canonical_cells = [_canonical_inline(cell) for cell in cells]
        if not all(isinstance(cell, list) for cell in canonical_cells):
            raise ValueError("table cell is not losslessly canonicalizable")
        rows.append(canonical_cells)
        row_headers.append(header)

    head = None
    if isinstance(explicit_head, list):
        head = [_canonical_inline(cell) for cell in explicit_head]
        if not all(isinstance(cell, list) for cell in head):
            raise ValueError("table header is not losslessly canonicalizable")
    elif rows and row_headers[0]:
        head = rows.pop(0)

    normalized = {
        key: copy.deepcopy(value)
        for key, value in block.items()
        if key not in {"content", "head", "header", "rows"}
    }
    normalized.update({"type": "table", "rows": rows})
    if head is not None:
        normalized["head"] = head
    return normalized


def canonicalize_blocks(blocks: Any) -> Any:
    """Apply only deterministic, semantics-preserving wire canonicalizations."""
    if not isinstance(blocks, list):
        return blocks

    normalized: list[Any] = []
    for raw_block in blocks:
        if not isinstance(raw_block, dict):
            normalized.append(raw_block)
            continue
        if _empty_paragraph(raw_block):
            continue
        block = dict(raw_block)
        block_type = block.get("type")
        block_token = _type_token(block)

        if block_token in {"list", "bulletlist", "orderedlist"} and (
            block_type != "list" or not isinstance(block.get("items"), list)
        ):
            try:
                block = _normalize_list_dialect(block)
            except (TypeError, ValueError):
                pass
            block_type = block.get("type")

        if block_token == "table" and not isinstance(block.get("rows"), list):
            try:
                block = _normalize_table_content_dialect(block)
            except (TypeError, ValueError):
                pass
            block_type = block.get("type")

        if (
            block_type == "list"
            and "items" not in block
            and isinstance(block.get("content"), list)
        ):
            content_items = block["content"]
            canonical_items = []
            content_dialect = True
            for item in content_items:
                if (
                    isinstance(item, dict)
                    and _type_token(item) == "listitem"
                    and isinstance(item.get("content"), list)
                ):
                    canonical_items.append(_canonical_inline(item))
                elif isinstance(item, dict) and _type_token(item) == "text":
                    canonical_items.append([item])
                else:
                    content_dialect = False
                    break
            if content_dialect:
                block["items"] = canonical_items
                block.pop("content", None)

        if block_type == "list" and isinstance(block.get("items"), list):
            items = []
            for item in block["items"]:
                items.append(_canonical_list_item(item))
            block["items"] = items

        if (
            block_type == "table"
            and "rows" not in block
            and isinstance(block.get("content"), list)
        ):
            content_rows = block["content"]
            canonical_rows = []
            content_dialect = True
            header_flags = []
            for row in content_rows:
                if (
                    not isinstance(row, dict)
                    or _type_token(row) != "tablerow"
                    or not isinstance(row.get("content"), list)
                ):
                    content_dialect = False
                    break
                canonical_row = []
                row_headers = []
                for cell in row["content"]:
                    if (
                        not isinstance(cell, dict)
                        or _type_token(cell) != "tablecell"
                        or not isinstance(cell.get("content"), list)
                    ):
                        content_dialect = False
                        break
                    canonical_row.append(_canonical_inline(cell))
                    row_headers.append(cell.get("header") is True)
                if not content_dialect:
                    break
                canonical_rows.append(canonical_row)
                header_flags.append(bool(row_headers) and all(row_headers))

            if content_dialect:
                if canonical_rows and header_flags[0]:
                    block["head"] = canonical_rows[0]
                    canonical_rows = canonical_rows[1:]
                block["rows"] = canonical_rows
                block.pop("content", None)

        if block_type == "table" and isinstance(block.get("rows"), list):
            headers = block.get("headers")
            if (
                not block.get("head")
                and isinstance(headers, list)
                and all(_record_scalar(cell) for cell in headers)
            ):
                block["head"] = [_canonical_inline(cell) for cell in headers]
                block.pop("headers", None)

            header = block.get("header")
            if (
                not block.get("head")
                and isinstance(header, list)
                and all(_record_scalar(cell) for cell in header)
            ):
                block["head"] = [_canonical_inline(cell) for cell in header]
                block.pop("header", None)

            if isinstance(block.get("head"), list):
                block["head"] = [
                    _canonical_inline(cell) for cell in block["head"]
                ]

            columns = block.get("columns")
            legacy_columns = (
                isinstance(columns, list)
                and bool(columns)
                and all(
                    isinstance(column, dict)
                    and set(column).issubset({"text"})
                    and isinstance(column.get("text"), str)
                    for column in columns
                )
            )
            if legacy_columns and not block.get("head") and not block.get("header"):
                block["head"] = [
                    _text_node(column["text"]) for column in columns  # type: ignore[index]
                ]
                block.pop("columns", None)
                columns = None
            if isinstance(columns, list) and columns:
                keys = [
                    column.get("key") if isinstance(column, dict) else None
                    for column in columns
                ]
                valid = (
                    all(isinstance(key, str) and key for key in keys)
                    and len(set(keys)) == len(keys)
                    and all(
                        isinstance(column, dict)
                        and (
                            column.get("label") is None
                            or isinstance(column.get("label"), str)
                        )
                        for column in columns
                    )
                    and all(
                        isinstance(row, dict)
                        and set(row).issubset(keys)
                        and all(_record_scalar(value) for value in row.values())
                        for row in block["rows"]
                    )
                )
                if valid:
                    block["head"] = [
                        _text_node(
                            column.get("label") or column["key"]  # type: ignore[union-attr]
                        )
                        for column in columns
                    ]
                    block["rows"] = [
                        [_text_node(row.get(key, "")) for key in keys]  # type: ignore[arg-type]
                        for row in block["rows"]
                    ]
                    block.pop("columns", None)

            rows = block.get("rows", [])
            if isinstance(rows, list) and rows:
                first = rows[0]
                first_cells = first.get("cells") if isinstance(first, dict) else None
                row_header = isinstance(first, dict) and first.get("header") is True
                cell_header = (
                    isinstance(first_cells, list)
                    and bool(first_cells)
                    and all(
                        isinstance(cell, dict) and cell.get("header") is True
                        for cell in first_cells
                    )
                )
                if (
                    not block.get("head")
                    and isinstance(first_cells, list)
                    and (row_header or cell_header)
                ):
                    block["head"] = [
                        _canonical_cell(cell, header=True) for cell in first_cells
                    ]
                    rows = rows[1:]

                normalized_rows = []
                for row in rows:
                    if (
                        isinstance(row, dict)
                        and set(row).issubset({"cells", "header"})
                        and row.get("header") is not True
                        and isinstance(row.get("cells"), list)
                    ):
                        row = [
                            _canonical_cell(cell) for cell in row.get("cells", [])
                        ]
                    elif isinstance(row, list):
                        row = [_canonical_inline(cell) for cell in row]
                    normalized_rows.append(row)
                block["rows"] = normalized_rows

        if (
            block_type == "callout"
            and isinstance(block.get("text"), str)
            and block["text"].strip()
            and block.get("content") in (None, [])
            and block.get("slots") in (None, {})
        ):
            block["content"] = _text_node(block.pop("text"))

        if isinstance(block.get("blocks"), list):
            block["blocks"] = canonicalize_blocks(block["blocks"])
        if isinstance(block.get("children"), list):
            block["children"] = canonicalize_blocks(block["children"])

        normalized.append(block)
    return normalized


def audit_documents(documents: Iterable[dict[str, Any]]) -> dict[str, Any]:
    docs = sorted(documents, key=lambda item: str(item.get("_id", "")))
    findings: list[dict[str, Any]] = []
    empty_paragraphs = 0

    for document in docs:
        blocks = document.get("blocks")
        # HTML-only Papers are a supported legacy form. Only audit a structural
        # body when the document actually declares one.
        if "blocks" in document:
            findings.extend(audit_blocks(document, blocks))
        if isinstance(blocks, list):
            empty_paragraphs += sum(
                1 for block in blocks if _empty_paragraph(block)
            )

    findings.sort(key=lambda item: (item["paper_id"], item["path"], item["kind"]))
    affected = sorted({item["paper_id"] for item in findings})
    kind_counts = Counter(item["kind"] for item in findings)
    canonical = json.dumps(findings, sort_keys=True, separators=(",", ":")).encode()

    return {
        "schema": "barkpark.paper-structure-audit.v1",
        "papers_scanned": len(docs),
        "papers_affected": len(affected),
        "affected_paper_ids": affected,
        "violations": len(findings),
        "safe_repair_violations": sum(item["safe_repair"] for item in findings),
        "quarantined_violations": sum(not item["safe_repair"] for item in findings),
        "violation_counts": dict(sorted(kind_counts.items())),
        "empty_top_level_paragraphs": empty_paragraphs,
        "findings_sha256": hashlib.sha256(canonical).hexdigest(),
        "findings": findings,
    }


def iter_live_documents(
    *, server: str, dataset: str, page_size: int, manifest: Path | None = None
) -> Iterator[dict[str, Any]]:
    offset = 0
    while True:
        command = ["bp"]
        if manifest is not None:
            command.extend(["--manifest", str(manifest)])
        command.extend(
            [
            "-s",
            server,
            "-d",
            dataset,
            "doc",
            "ls",
            "paper",
            "--limit",
            str(page_size),
            "--offset",
            str(offset),
            "-o",
            "json",
            ]
        )
        result = None
        for attempt in range(3):
            candidate = subprocess.run(command, capture_output=True, text=True)
            if candidate.returncode == 0:
                result = candidate
                break
            if attempt < 2:
                time.sleep(1 + attempt)
        if result is None:
            raise RuntimeError(
                f"bp page failed after 3 attempts at offset {offset}: "
                f"{candidate.stderr.strip()}"
            )
        page = json.loads(result.stdout)
        documents = page.get("documents", [])
        if not isinstance(documents, list):
            raise ValueError("bp doc ls returned a non-array documents field")
        yield from documents
        if len(documents) < page_size:
            break
        offset += page_size


def _load_input(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text())
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("documents"), list):
        return payload["documents"]
    if isinstance(payload, dict) and "_id" in payload:
        return [payload]
    raise ValueError("input must be a Paper, an array of Papers, or a page object")


def write_repair_plan(
    documents: Iterable[dict[str, Any]], plan_dir: Path, *, chunk_size: int = 25
) -> dict[str, Any]:
    if plan_dir.exists() and any(plan_dir.iterdir()):
        raise ValueError(f"refusing non-empty plan directory: {plan_dir}")
    plan_dir.mkdir(parents=True, exist_ok=True)
    backup_dir = plan_dir / "backups"
    mutation_dir = plan_dir / "mutations"
    backup_dir.mkdir()
    mutation_dir.mkdir()

    repairs: list[list[dict[str, Any]]] = []
    post_repair_documents: list[dict[str, Any]] = []
    ordered_documents = sorted(
        documents, key=lambda item: str(item.get("_id", ""))
    )
    inventory_bytes = json.dumps(
        [[doc.get("_id"), doc.get("_rev")] for doc in ordered_documents],
        separators=(",", ":"),
    ).encode()

    for document in ordered_documents:
        blocks = document.get("blocks")
        normalized = canonicalize_blocks(blocks)
        post_document = dict(document)
        if "blocks" in document:
            post_document["blocks"] = normalized
        post_repair_documents.append(post_document)
        if normalized == blocks:
            continue
        paper_id = document.get("_id")
        revision = document.get("_rev")
        if not isinstance(paper_id, str) or not isinstance(revision, str):
            raise ValueError("repairable Paper lacks _id/_rev")
        backup = json.dumps(document, indent=2, sort_keys=True) + "\n"
        (backup_dir / f"{paper_id}.json").write_text(backup)
        repairs.append(
            [
                {
                    "patch": {
                        "id": paper_id,
                        "type": "paper",
                        "set": {"blocks": normalized},
                        "ifRevisionID": revision,
                    }
                },
                {
                    "publish": {
                        "id": paper_id,
                        "type": "paper",
                    }
                }
            ]
        )

    for index in range(0, len(repairs), chunk_size):
        groups = repairs[index : index + chunk_size]
        chunk = {"mutations": [mutation for group in groups for mutation in group]}
        path = mutation_dir / f"repair-{index // chunk_size + 1:03d}.json"
        path.write_text(json.dumps(chunk, indent=2, sort_keys=True) + "\n")

    post_repair = audit_documents(post_repair_documents)
    manifest = {
        "schema": "barkpark.paper-structure-repair-plan.v1",
        "papers_scanned": len(ordered_documents),
        "papers_changed": len(repairs),
        "mutation_chunks": (len(repairs) + chunk_size - 1) // chunk_size,
        "chunk_size": chunk_size,
        "revision_fenced": True,
        "backup_documents": len(repairs),
        "inventory_sha256": hashlib.sha256(inventory_bytes).hexdigest(),
        "post_repair_violations": post_repair["violations"],
        "post_repair_findings_sha256": post_repair["findings_sha256"],
    }
    (plan_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--server", default="guerrilla")
    parser.add_argument("--dataset", default="production")
    parser.add_argument(
        "--manifest",
        type=Path,
        help="Use an offline bp capability manifest for bounded live reads.",
    )
    parser.add_argument("--page-size", type=int, default=25)
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--plan-dir", type=Path)
    args = parser.parse_args(argv)

    if args.input:
        documents = _load_input(args.input)
    else:
        documents = list(
            iter_live_documents(
                server=args.server,
                dataset=args.dataset,
                page_size=args.page_size,
                manifest=args.manifest,
            )
        )

    report = audit_documents(documents)
    if args.plan_dir:
        report["repair_plan"] = write_repair_plan(documents, args.plan_dir)
    if args.summary_only:
        report = {key: value for key, value in report.items() if key != "findings"}
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 1 if report["violations"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
