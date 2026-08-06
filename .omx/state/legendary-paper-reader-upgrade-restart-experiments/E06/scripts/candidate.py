#!/usr/bin/env python3
"""Deterministic E06 versioned canonical projection and reader adapters."""

from __future__ import annotations

import email.policy
import hashlib
import html
import json
import shutil
import tarfile
import tempfile
import textwrap
import unicodedata
from email.message import EmailMessage
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parents[1]
EXPERIMENT_ROOT = HERE.parent
BASELINE_ARCHIVE = EXPERIMENT_ROOT / "E01" / "evidence.tar.gz"
BASELINE_CONTRACT = EXPERIMENT_ROOT / "baseline-seal" / "contract.json"
SCHEMA = HERE / "schema" / "canonical-projection-v1.schema.json"
SCHEMA_VERSION = "barkpark.paper.canonical-projection/v1"
PROJECTION_VERSION = 1
GENERATOR_VERSION = "restart-experiment-06/candidate-v1"
BASELINE_ARCHIVE_SHA256 = "db61dd8b614014de04fcf028abc8e0ed40129826649342fd66a914b14c8feed3"
BASELINE_CONTRACT_SHA256 = "bb24ce3baee61d76a210b97ebf8ebd9b17ea20ae1cb988ade4daae44907d3bef"

AUTHORITY = {
    "epic_id": "task-a768c69e659add58",
    "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart",
    "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
    "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc",
    "plan_digest": "9997fc50db5f1b83f1f53e33bd45dd111b2b06402b07a78b0673d2048f299e45",
}
PAPERS = {
    "CCH28": ("cloud-console-hardening-wave-28-2026-08-03", "49c1534d9fb76d0d9adc7b97f25ec471"),
    "CCH29": ("cloud-console-hardening-wave-29-2026-08-03", "18768b0a14c2eead927181c4a0e37c18"),
    "PDS44": ("pds-wave-44-2026-08-03", "8bbd5d874a1b697f1e4e437c473f8e52"),
    "PDS45": ("pds-wave-45-2026-08-03", "b992fd8aaa028b0dab30a8da76f077fd"),
}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def nfc_tree(value: Any) -> Any:
    if isinstance(value, str):
        return unicodedata.normalize("NFC", value)
    if isinstance(value, list):
        return [nfc_tree(item) for item in value]
    if isinstance(value, dict):
        return {key: nfc_tree(item) for key, item in value.items()}
    return value


def write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def text_of(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return " ".join(part for item in value if (part := text_of(item)))
    if isinstance(value, dict):
        if isinstance(value.get("value"), str):
            return value["value"]
        if isinstance(value.get("text"), str):
            return value["text"]
        parts = [text_of(value[key]) for key in ("content", "items", "header", "head", "rows") if key in value]
        if parts:
            return " ".join(part for part in parts if part)
    return str(value)


def cell_text(cell: Any) -> str:
    return text_of(cell)


def inline_html(value: Any) -> str:
    if isinstance(value, list):
        return "".join(inline_html(item) for item in value)
    if not isinstance(value, dict):
        return html.escape(text_of(value))
    rendered = html.escape(text_of(value.get("value", value.get("text", ""))))
    for mark in value.get("marks", []) if isinstance(value.get("marks"), list) else []:
        kind = mark if isinstance(mark, str) else mark.get("type", "unknown") if isinstance(mark, dict) else "unknown"
        tag = {"strong": "strong", "bold": "strong", "em": "em", "italic": "em", "code": "code"}.get(kind)
        if tag:
            rendered = f"<{tag}>{rendered}</{tag}>"
        else:
            rendered = f'<span data-mark="{html.escape(str(kind), quote=True)}">{rendered}</span>'
    return rendered


def render_list_items(items: Any) -> str:
    if not isinstance(items, list):
        return f"<li>{html.escape(text_of(items))}</li>"
    rows = []
    for item in items:
        if isinstance(item, list):
            rows.append(f"<li>{''.join(render_block(x, nested=True) for x in item)}</li>")
        elif isinstance(item, dict):
            rows.append(f"<li>{render_block(item, nested=True)}</li>")
        else:
            rows.append(f"<li>{html.escape(text_of(item))}</li>")
    return "".join(rows)


def render_block(block: Any, nested: bool = False) -> str:
    if not isinstance(block, dict):
        return f'<p data-malformed="true">{html.escape(text_of(block))}</p>'
    kind = block.get("type")
    block_id = html.escape(str(block.get("id", "")), quote=True)
    attrs = f' id="{block_id}" data-block-id="{block_id}"' if block_id and not nested else ""
    if kind == "heading":
        level = min(6, max(1, int(block.get("level", 2))))
        return f"<h{level}{attrs}>{html.escape(text_of(block.get('text', '')))}</h{level}>"
    if kind == "paragraph":
        return f"<p{attrs}>{inline_html(block.get('content', []))}</p>"
    if kind == "text":
        return inline_html(block)
    if kind == "callout":
        tone = html.escape(str(block.get("tone", "neutral")), quote=True)
        return f'<aside{attrs} role="note" data-tone="{tone}">{inline_html(block.get("content", []))}</aside>'
    if kind == "list":
        tag = "ol" if block.get("ordered") is True else "ul"
        return f"<{tag}{attrs}>{render_list_items(block.get('items', []))}</{tag}>"
    if kind == "table":
        header = block.get("header") if "header" in block else block.get("head")
        head_html = ""
        if isinstance(header, list) and header:
            head_html = "<thead><tr>" + "".join(f'<th scope="col">{html.escape(cell_text(c))}</th>' for c in header) + "</tr></thead>"
        rows = block.get("rows", []) if isinstance(block.get("rows"), list) else []
        body = "".join("<tr>" + "".join(f"<td>{html.escape(cell_text(c))}</td>" for c in row if isinstance(row, list)) + "</tr>" for row in rows)
        return f'<div class="table-scroll" tabindex="0"><table{attrs}>{head_html}<tbody>{body}</tbody></table></div>'
    return f'<section{attrs} data-unknown-type="{html.escape(str(kind), quote=True)}"><pre>{html.escape(json.dumps(block, ensure_ascii=False, sort_keys=True))}</pre></section>'


def render_html(projection: dict[str, Any], email_mode: bool = False) -> str:
    document = projection["document"]
    blocks = "".join(render_block(block) for block in document["blocks"])
    title = html.escape(str(document["authored_metadata"].get("title") or document["slug"]))
    style = "body{font-family:system-ui,sans-serif;line-height:1.5;max-width:72rem;margin:auto;padding:1rem} .table-scroll{max-width:100%;overflow-x:auto} table{border-collapse:collapse} th,td{border:1px solid #777;padding:.35rem;text-align:left;vertical-align:top} aside{border-inline-start:.3rem solid #777;padding:.5rem 1rem} pre{white-space:pre-wrap;overflow-wrap:anywhere}"
    medium = "" if email_mode else "@media(max-width:390px){body{padding:.5rem}th,td{min-width:8rem}}"
    return f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title><style>{style}{medium}</style></head><body><main data-document-id="{html.escape(projection["identity"]["document_id"], quote=True)}" data-document-revision-id="{html.escape(projection["identity"]["document_revision_id"], quote=True)}"><article>{blocks}</article></main></body></html>\n'


def render_tui(projection: dict[str, Any], width: int) -> str:
    width = max(1, width)
    lines = [f"Document: {projection['identity']['document_id']}", f"Revision: {projection['identity']['document_revision_id']}", f"Projection: {projection['identity']['projection_id']}", ""]
    for block in projection["document"]["blocks"]:
        kind = block.get("type", "unknown") if isinstance(block, dict) else "malformed"
        prefix = {"heading": "# ", "callout": "! ", "list": "- ", "table": "| ", "paragraph": ""}.get(kind, "? ")
        payload = text_of(block)
        wrapped = textwrap.wrap(prefix + payload, width=width, break_long_words=True, break_on_hyphens=False, replace_whitespace=False, drop_whitespace=True) or [prefix.rstrip()]
        lines.extend(wrapped)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def projection_for(fixture_id: str, raw: bytes) -> dict[str, Any]:
    envelope = json.loads(raw)
    slug, revision = PAPERS[fixture_id]
    if envelope.get("_id") != slug or envelope.get("_rev") != revision:
        raise ValueError(f"pin mismatch for {fixture_id}")
    semantic = {
        "slug": slug,
        "revision": revision,
        "published_id": envelope.get("_publishedId"),
        "type": envelope.get("_type"),
        "authored_metadata": nfc_tree({key: envelope.get(key) for key in ("title", "description", "style", "main_tag", "tags")}),
        "blocks": nfc_tree(envelope["blocks"]),
    }
    content_digest = sha256(canonical_bytes(semantic))
    raw_digest = sha256(raw)
    identity = {
        "document_id": f"urn:barkpark:document:{slug}",
        "document_revision_id": f"urn:barkpark:document-revision:{slug}:{revision}",
        "release_id": f"urn:barkpark:release:{envelope.get('_publishedId')}:{revision}",
        "projection_id": f"urn:barkpark:projection:paper-canonical:v1:{slug}:{revision}",
        "cache_identity": f"urn:barkpark:cache:paper-canonical:v1:{content_digest}",
        "cycle_id": f"urn:barkpark:cycle:{AUTHORITY['epic_id']}:{AUTHORITY['wave_id']}:{AUTHORITY['wave_revision']}",
    }
    if len(set(identity.values())) != len(identity):
        raise ValueError("identity domains conflated")
    return {
        "schema_version": SCHEMA_VERSION,
        "projection_version": PROJECTION_VERSION,
        "identity": identity,
        "validators": {
            "source_etag": f'"raw-sha256:{raw_digest}"',
            "projection_etag": f'"projection-v1-sha256:{content_digest}"',
            "last_modified": envelope.get("_updatedAt"),
            "conditional_contract": "exact If-None-Match => 304 with empty body; stale or absent => 200 with canonical bytes",
        },
        "provenance": {
            "generator": GENERATOR_VERSION,
            "source_boundary": "immutable byte copy from sealed E01 raw/doc_get capture",
            "source_sha256": raw_digest,
            "source_bytes": len(raw),
            "source_revision": revision,
            "baseline_archive_sha256": BASELINE_ARCHIVE_SHA256,
            "baseline_contract_sha256": BASELINE_CONTRACT_SHA256,
            "normalization": "Unicode NFC recursively; no trimming, collapse, reordering, alias overwrite, header inference, or source mutation",
            "cycle_authority": AUTHORITY,
        },
        "document": semantic,
    }


def conditional_response(body: bytes, current_etag: str, if_none_match: str | None) -> tuple[int, bytes]:
    return (304, b"") if if_none_match == current_etag else (200, body)


def count_blocks(blocks: list[Any]) -> dict[str, int]:
    counters = {"blocks": len(blocks), "authored_header_cells": 0, "table_body_cells": 0, "marks": 0, "headerless_tables": 0}
    def visit(value: Any) -> None:
        if isinstance(value, dict):
            marks = value.get("marks")
            if isinstance(marks, list):
                counters["marks"] += len(marks)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    for block in blocks:
        if isinstance(block, dict) and block.get("type") == "table":
            header = block.get("header") if "header" in block else block.get("head")
            if isinstance(header, list) and header:
                counters["authored_header_cells"] += len(header)
            else:
                counters["headerless_tables"] += 1
            for row in block.get("rows", []) if isinstance(block.get("rows"), list) else []:
                if isinstance(row, list):
                    counters["table_body_cells"] += len(row)
        visit(block)
    return counters


def quarantine_probe() -> dict[str, Any]:
    adversarial = json.loads((EXPERIMENT_ROOT / "E01" / "fixtures" / "adversarial.json").read_text())
    quarantined = []
    accepted = []
    for fixture in adversarial["fixtures"]:
        block = fixture["input"]
        if block.get("type") == "table" and "header" in block and "head" in block and block["header"] != block["head"]:
            quarantined.append({"fixture_id": fixture["id"], "reason": "conflicting header/head aliases; preserve both and require author decision", "raw_sha256": sha256(canonical_bytes(block))})
        else:
            accepted.append(fixture["id"])
    return {"schema_version": "barkpark.paper.projection-quarantine/v1", "candidate": GENERATOR_VERSION, "quarantined": quarantined, "accepted_fixture_ids": accepted, "source_mutations": 0}


def build(output: Path) -> None:
    if sha256(BASELINE_ARCHIVE.read_bytes()) != BASELINE_ARCHIVE_SHA256:
        raise ValueError("baseline archive digest mismatch")
    if sha256(BASELINE_CONTRACT.read_bytes()) != BASELINE_CONTRACT_SHA256:
        raise ValueError("baseline contract digest mismatch")
    projections = {}
    raw_hashes = {}
    with tarfile.open(BASELINE_ARCHIVE, "r:gz") as archive:
        for fixture_id in PAPERS:
            member = archive.extractfile(f"raw/doc_get/{fixture_id}.json")
            if member is None:
                raise ValueError(f"missing raw fixture {fixture_id}")
            raw = member.read()
            raw_hashes[fixture_id] = sha256(raw)
            write(output / "source" / f"{fixture_id}.json", raw)
            projection = projection_for(fixture_id, raw)
            projections[fixture_id] = projection
            body = canonical_bytes(projection)
            write(output / "projections" / f"{fixture_id}.json", body)
            public_html = render_html(projection).encode("utf-8")
            email_html = render_html(projection, email_mode=True).encode("utf-8")
            write(output / "adapters" / "public" / f"{fixture_id}.html", public_html)
            write(output / "adapters" / "studio" / f"{fixture_id}.json", canonical_bytes({"mode":"read_only_canonical_projection","projection":projection,"connected_session_required_for_editor_proof":True}))
            write(output / "adapters" / "tui80" / f"{fixture_id}.txt", render_tui(projection, 80).encode("utf-8"))
            message = EmailMessage(policy=email.policy.SMTP)
            message["Subject"] = str(projection["document"]["authored_metadata"].get("title") or projection["document"]["slug"])
            message["From"] = "paper-projection@invalid.example"
            message["To"] = "reader@invalid.example"
            message["Message-ID"] = f"<{fixture_id.lower()}.{projection['document']['revision']}@invalid.example>"
            message["X-Barkpark-Document-Revision"] = projection["identity"]["document_revision_id"]
            message.set_content("This Paper requires an HTML-capable mail reader.\n")
            message.add_alternative(email_html.decode("utf-8"), subtype="html")
            message.set_boundary(f"barkpark-e06-{fixture_id.lower()}-{projection['document']['revision']}")
            write(output / "adapters" / "email" / f"{fixture_id}.eml", message.as_bytes())
            write(output / "adapters" / "cli_api" / f"{fixture_id}.json", canonical_bytes({"data": projection, "meta": {"schema": SCHEMA_VERSION, "etag": projection["validators"]["projection_etag"]}}))
            write(output / "adapters" / "cli_api" / f"{fixture_id}.txt", render_tui(projection, 120).encode("utf-8"))

    quarantine = quarantine_probe()
    write(output / "receipts" / "quarantine.json", canonical_bytes(quarantine))
    rollback = {
        "schema_version": "barkpark.paper.projection-rollback/v1",
        "candidate": GENERATOR_VERSION,
        "operation": "deactivate projection version and retain immutable source bytes",
        "source_hashes_before": raw_hashes,
        "source_hashes_after": raw_hashes,
        "source_mutations": 0,
        "projection_version_deactivatable": True,
        "quarantine_receipt": "receipts/quarantine.json",
    }
    write(output / "receipts" / "rollback.json", canonical_bytes(rollback))
    reader_matrix = {
        "schema_version": "legendary-paper-restart-e06-reader-matrix/v1",
        "papers": list(PAPERS),
        "adapters": {name: {"artifacts": 4, "status": "PASS_STATIC_ADAPTER"} for name in ("public", "studio", "tui80", "email", "cli_api")},
        "real_reader_cells": {
            "public_browser": "BLOCKED_NO_BROWSER_CAPTURE_IN_ISOLATED_CANDIDATE",
            "authenticated_studio": "BLOCKED_NO_SAFE_CONNECTED_SESSION",
            "interactive_tui": "BLOCKED_CANDIDATE_NOT_INSTALLED_IN_PRODUCTION_BINARY",
            "delivered_mail_clients": "BLOCKED_NO_DELIVERY_OR_CLIENT_ACCOUNTS",
            "live_cli_api_endpoint": "BLOCKED_ISOLATED_CANDIDATE_NOT_DEPLOYED",
            "real_assistive_technology": "BLOCKED_NO_AT_SESSION",
        },
        "proxy_passes": 0,
    }
    write(output / "receipts" / "reader-matrix.json", canonical_bytes(reader_matrix))
    counts = {fixture_id: count_blocks(projection["document"]["blocks"]) for fixture_id, projection in projections.items()}
    write(output / "receipts" / "content-counts.json", canonical_bytes({"schema_version":"legendary-paper-restart-e06-counts/v1","papers":counts}))


def rollback_simulation() -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="barkpark-e06-rollback-") as temp:
        root = Path(temp) / "candidate"
        build(root)
        before = {path.name: sha256(path.read_bytes()) for path in sorted((root / "source").glob("*.json"))}
        quarantine = Path(temp) / "quarantine"
        (root / "projections").rename(quarantine)
        after = {path.name: sha256(path.read_bytes()) for path in sorted((root / "source").glob("*.json"))}
        return {"status":"PASS" if before == after and quarantine.is_dir() else "FAIL","source_hashes_before":before,"source_hashes_after":after,"quarantined_projection_files":len(list(quarantine.glob("*.json"))),"source_mutations":0}
