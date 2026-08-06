#!/usr/bin/env python3
"""Lossless semantic core and thin deterministic reader adapters for E05."""

from __future__ import annotations

import hashlib
import html
import json
import re
import textwrap
import unicodedata
from pathlib import Path
from typing import Any, Iterable

PAPER_IDS = ("CCH28", "CCH29", "PDS44", "PDS45")
WAVE_REVISION = "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737"


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def nfc(value: Any) -> Any:
    if isinstance(value, str):
        return unicodedata.normalize("NFC", value)
    if isinstance(value, list):
        return [nfc(item) for item in value]
    if isinstance(value, dict):
        return {key: nfc(item) for key, item in value.items()}
    return value


def semantic_core(raw: bytes) -> dict[str, Any]:
    source = json.loads(raw)
    blocks = source.get("blocks")
    if not isinstance(blocks, list):
        raise ValueError("Paper source must contain a blocks list")
    semantic = {
        "identity": {
            "document_id": source.get("_publishedId") or source.get("_id"),
            "release_revision": source.get("_rev"),
            "type": source.get("_type"),
        },
        "authored_metadata": {
            "description": nfc(source.get("description")),
            "main_tag": nfc(source.get("main_tag")),
            "style": nfc(source.get("style")),
            "tags": nfc(source.get("tags")),
            "title": nfc(source.get("title")),
        },
        "blocks": nfc(blocks),
    }
    semantic_hash = sha256_bytes(canonical_bytes(semantic))
    document_id = semantic["identity"]["document_id"]
    revision = semantic["identity"]["release_revision"]
    cache_key = sha256_bytes(f"{document_id}:{revision}:{semantic_hash}".encode())
    return {
        "schema_version": "legendary-restart-e05-semantic-core/v1",
        "normalization": "Unicode NFC only; no trimming, alias rewriting, header inference, reordering, or source mutation",
        "source_receipt": {"bytes": len(raw), "sha256": sha256_bytes(raw)},
        "identity_receipt": {
            "document_identity": document_id,
            "release_identity": revision,
            "cache_identity": cache_key,
            "cycle_identity": WAVE_REVISION,
            "etag": f'\"{cache_key}\"',
            "domains_distinct": len({document_id, revision, cache_key, WAVE_REVISION}) == 4,
        },
        "semantic_sha256": semantic_hash,
        "value": semantic,
    }


def iter_text(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from iter_text(item)
    elif isinstance(value, dict):
        if value.get("type") == "text" and isinstance(value.get("value"), str):
            yield value["value"]
            return
        for key, item in value.items():
            if key not in {"id", "type", "marks", "tone", "style", "role", "level", "ordered"}:
                yield from iter_text(item)


def text_of(value: Any) -> str:
    return "".join(iter_text(value))


def inline_html(value: Any) -> str:
    if isinstance(value, str):
        return html.escape(value)
    if isinstance(value, list):
        return "".join(inline_html(item) for item in value)
    if not isinstance(value, dict):
        return html.escape(str(value))
    if value.get("type") == "text":
        rendered = html.escape(str(value.get("value", "")))
        for mark in value.get("marks") or []:
            if isinstance(mark, str):
                tag = {"strong": "strong", "em": "em", "code": "code", "underline": "u", "strike": "s"}.get(mark)
                rendered = f"<{tag}>{rendered}</{tag}>" if tag else f'<span data-mark="{html.escape(mark)}">{rendered}</span>'
                continue
            mark_type = str(mark.get("type", "object")) if isinstance(mark, dict) else type(mark).__name__
            href = mark.get("href") if isinstance(mark, dict) else None
            if mark_type == "link" and isinstance(href, str) and re.match(r"^(?:https?://|mailto:|/|#)", href):
                rendered = f'<a href="{html.escape(href, quote=True)}">{rendered}</a>'
            else:
                rendered = f'<span data-mark-type="{html.escape(mark_type, quote=True)}">{rendered}</span>'
        return rendered
    return html.escape(text_of(value))


def cells_html(cells: Any, tag: str) -> str:
    if not isinstance(cells, list):
        return ""
    return "".join(f"<{tag}>{inline_html(cell)}</{tag}>" for cell in cells)


def block_html(block: dict[str, Any]) -> str:
    kind = block.get("type")
    block_id = html.escape(str(block.get("id", "")))
    if kind == "heading":
        level = min(6, max(1, int(block.get("level", 2))))
        return f'<h{level} id="{block_id}">{html.escape(str(block.get("text", "")))}</h{level}>'
    if kind == "paragraph":
        return f'<p id="{block_id}">{inline_html(block.get("content", []))}</p>'
    if kind == "list":
        tag = "ol" if block.get("ordered") else "ul"
        items = "".join(f"<li>{inline_html(item)}</li>" for item in block.get("items", []))
        return f'<{tag} id="{block_id}">{items}</{tag}>'
    if kind == "table":
        head = block.get("header")
        header = f"<thead><tr>{cells_html(head, 'th')}</tr></thead>" if isinstance(head, list) and head else ""
        rows = "".join(f"<tr>{cells_html(row, 'td')}</tr>" for row in block.get("rows", []))
        return f'<div class="table-scroll" role="region" aria-label="Table"><table id="{block_id}">{header}<tbody>{rows}</tbody></table></div>'
    if kind == "callout":
        tone = html.escape(str(block.get("tone", "note")))
        return f'<aside id="{block_id}" class="callout callout-{tone}" aria-label="{tone} callout">{inline_html(block.get("content", block))}</aside>'
    return f'<section id="{block_id}" data-portable-type="{html.escape(str(kind))}"><pre>{html.escape(json.dumps(block, ensure_ascii=False, sort_keys=True))}</pre></section>'


def public_adapter(core: dict[str, Any]) -> bytes:
    value = core["value"]
    body = "".join(block_html(block) for block in value["blocks"])
    title = html.escape(str(value["authored_metadata"].get("title") or value["identity"]["document_id"]))
    document_id = html.escape(str(value["identity"]["document_id"]))
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            f"<title>{title}</title><style>body{{overflow-wrap:anywhere}}table{{border-collapse:collapse;max-width:100%}}"
            ".table-scroll{max-width:100%;overflow-x:auto}th,td{vertical-align:top}</style></head>"
            f"<body><main data-document-id=\"{document_id}\">{body}</main></body></html>").encode("utf-8")


def studio_adapter(core: dict[str, Any]) -> bytes:
    return canonical_bytes({
        "schema_version": "legendary-restart-e05-studio-adapter/v1",
        "connection": core["identity_receipt"],
        "document": core["value"],
        "conversion": "lossless semantic core; edit/save behavior intentionally not exercised",
        "real_reader_status": "BLOCKED_AUTHENTICATED_STUDIO_SESSION_UNAVAILABLE",
    }) + b"\n"


def tui_adapter(core: dict[str, Any], width: int = 80) -> bytes:
    lines: list[str] = []
    for block in core["value"]["blocks"]:
        kind = block.get("type", "unknown")
        prefix = {"heading": "# ", "list": "- ", "callout": "! ", "table": "| "}.get(kind, "")
        payload = text_of(block)
        if not payload and kind == "paragraph":
            lines.append("")
            continue
        wrapped = textwrap.wrap(prefix + payload, width=width, break_long_words=True, break_on_hyphens=False,
                                replace_whitespace=False, drop_whitespace=False) or [prefix.rstrip()]
        lines.extend(line.rstrip() for line in wrapped)
    return ("\n".join(lines) + "\n").encode("utf-8")


def email_adapter(core: dict[str, Any]) -> bytes:
    boundary = "barkpark-e05-boundary"
    plain = tui_adapter(core, 72).decode("utf-8")
    web = public_adapter(core).decode("utf-8")
    subject = str(core["value"]["authored_metadata"].get("title") or "Barkpark Paper").replace("\r", " ").replace("\n", " ")
    message = (
        "MIME-Version: 1.0\r\n"
        f"Subject: {subject}\r\n"
        f"Content-Type: multipart/alternative; boundary=\"{boundary}\"\r\n\r\n"
        f"--{boundary}\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
        f"{plain.replace(chr(10), chr(13)+chr(10))}\r\n"
        f"--{boundary}\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
        f"{web}\r\n--{boundary}--\r\n"
    )
    return message.encode("utf-8")


def cli_api_adapter(core: dict[str, Any]) -> bytes:
    receipt = core["identity_receipt"]
    return canonical_bytes({
        "schema_version": "legendary-restart-e05-cli-api-adapter/v1",
        "request_id": "e05-replay-deterministic",
        "status": 200,
        "content_type": "application/vnd.barkpark.paper+json;version=1",
        "perspective": "published",
        "etag": receipt["etag"],
        "conditional_get": {"if_none_match_equal_status": 304, "otherwise_status": 200},
        "identity": receipt,
        "data": core["value"],
    }) + b"\n"


ADAPTERS = {
    "public.html": public_adapter,
    "studio.json": studio_adapter,
    "tui80.txt": tui_adapter,
    "email.eml": email_adapter,
    "cli-api.json": cli_api_adapter,
}


def source_metrics(blocks: list[dict[str, Any]]) -> dict[str, int]:
    totals = {"blocks": len(blocks), "authored_header_cells": 0, "table_body_cells": 0, "marks": 0,
              "callouts": 0, "headerless_tables": 0, "exact_empty_spacers": 0, "cch29_nested_list_words": 0}
    for block in blocks:
        if block.get("type") == "table":
            header = block.get("header")
            if isinstance(header, list) and header:
                totals["authored_header_cells"] += len(header)
            else:
                totals["headerless_tables"] += 1
            totals["table_body_cells"] += sum(len(row) for row in block.get("rows", []) if isinstance(row, list))
        if block.get("type") == "callout":
            totals["callouts"] += 1
        if block.get("type") == "paragraph" and not text_of(block.get("content", [])):
            totals["exact_empty_spacers"] += 1
        if block.get("type") == "list":
            for item in block.get("items", []):
                if isinstance(item, list):
                    for node in item:
                        if isinstance(node, dict) and node.get("type") == "paragraph":
                            totals["cch29_nested_list_words"] += len(re.findall(r"\b\w+\b", text_of(node.get("content", [])), re.UNICODE))
        def walk(v: Any) -> None:
            if isinstance(v, dict):
                if v.get("type") == "text":
                    totals["marks"] += len(v.get("marks") or [])
                for child in v.values():
                    walk(child)
            elif isinstance(v, list):
                for child in v:
                    walk(child)
        walk(block)
    return totals


def credential_hits(data: bytes) -> list[str]:
    text = data.decode("utf-8", errors="ignore")
    patterns = {
        "bearer_token": r"Bearer\s+[A-Za-z0-9._~+/=-]{16,}",
        "private_key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "github_token": r"gh[pousr]_[A-Za-z0-9]{20,}",
        "aws_access_key": r"AKIA[0-9A-Z]{16}",
    }
    return [name for name, pattern in patterns.items() if re.search(pattern, text)]
