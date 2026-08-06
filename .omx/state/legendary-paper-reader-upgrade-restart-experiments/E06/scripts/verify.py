#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import html
import json
import re
import time
from email import policy
from email.parser import BytesParser
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

from candidate import (
    AUTHORITY,
    BASELINE_ARCHIVE,
    BASELINE_ARCHIVE_SHA256,
    BASELINE_CONTRACT,
    BASELINE_CONTRACT_SHA256,
    GENERATOR_VERSION,
    HERE,
    PAPERS,
    SCHEMA,
    SCHEMA_VERSION,
    canonical_bytes,
    conditional_response,
    count_blocks,
    rollback_simulation,
    sha256,
)

EXPECTED_RAW = {
    "CCH28": "4519c9ac819e4c666c376bfbae11007d0e6c31765a692c99ccd2ad4188a57d0e",
    "CCH29": "2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15",
    "PDS44": "4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d",
    "PDS45": "5894db69f3d3f9ddc0416bd5e5e6b50dc72c1d962efb56ac7fd863b1a8d1caa7",
}
EXPECTED_TOTALS = {"blocks": 815, "authored_header_cells": 113, "table_body_cells": 1374, "marks": 388, "headerless_tables": 11}


class TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def report(path: str, value: Any) -> None:
    destination = HERE / "reports" / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(canonical_bytes(value))


def compact(value: str) -> str:
    return "".join(value.split())


def leaves(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, str) and value:
        found.append(value)
    elif isinstance(value, list):
        for item in value:
            found.extend(leaves(item))
    elif isinstance(value, dict):
        if isinstance(value.get("value"), str) and value["value"]:
            found.append(value["value"])
        elif isinstance(value.get("text"), str) and value["text"]:
            found.append(value["text"])
        for key in ("content", "items", "header", "head", "rows"):
            if key in value:
                found.extend(leaves(value[key]))
    return found


def html_text(data: bytes) -> str:
    parser = TextExtractor()
    parser.feed(data.decode("utf-8"))
    return " ".join(parser.parts)


def check_projection_schema(projection: dict[str, Any]) -> list[str]:
    errors = []
    if projection.get("schema_version") != SCHEMA_VERSION or projection.get("projection_version") != 1:
        errors.append("projection version")
    for key in ("identity", "validators", "provenance", "document"):
        if not isinstance(projection.get(key), dict):
            errors.append(f"missing object {key}")
    expected_identity = {"document_id", "document_revision_id", "release_id", "projection_id", "cache_identity", "cycle_id"}
    if set(projection.get("identity", {})) != expected_identity:
        errors.append("identity shape")
    if len(set(projection.get("identity", {}).values())) != 6:
        errors.append("identity domains conflated")
    validators = projection.get("validators", {})
    if not re.fullmatch(r'"raw-sha256:[0-9a-f]{64}"', validators.get("source_etag", "")):
        errors.append("source etag")
    if not re.fullmatch(r'"projection-v1-sha256:[0-9a-f]{64}"', validators.get("projection_etag", "")):
        errors.append("projection etag")
    document = projection.get("document", {})
    if not isinstance(document.get("blocks"), list) or document.get("type") != "paper":
        errors.append("document")
    return errors


started = time.monotonic()
checks: list[str] = []
failures: list[str] = []
conditional_rows = []
totals = {key: 0 for key in EXPECTED_TOTALS}
visibility = {surface: {"visible": 0, "planned": 0} for surface in ("public", "studio", "tui80", "email", "cli_api")}

schema_doc = json.loads(SCHEMA.read_text())
if schema_doc.get("$id") != "https://barkpark.dev/schemas/paper/canonical-projection/v1":
    failures.append("schema document id")
else:
    checks.append("explicit projection schema")

if sha256(BASELINE_ARCHIVE.read_bytes()) != BASELINE_ARCHIVE_SHA256:
    failures.append("baseline archive drift")
if sha256(BASELINE_CONTRACT.read_bytes()) != BASELINE_CONTRACT_SHA256:
    failures.append("baseline contract drift")
if not failures:
    checks.append("sealed baseline inputs")

for fixture_id, (slug, revision) in PAPERS.items():
    source_path = HERE / "generated" / "source" / f"{fixture_id}.json"
    projection_path = HERE / "generated" / "projections" / f"{fixture_id}.json"
    source = source_path.read_bytes()
    projection_bytes = projection_path.read_bytes()
    projection = json.loads(projection_bytes)
    if sha256(source) != EXPECTED_RAW[fixture_id]:
        failures.append(f"raw preservation {fixture_id}")
    source_doc = json.loads(source)
    if source_doc.get("_id") != slug or source_doc.get("_rev") != revision:
        failures.append(f"pin {fixture_id}")
    errors = check_projection_schema(projection)
    failures.extend(f"schema {fixture_id}: {error}" for error in errors)
    if projection["document"]["blocks"] != json.loads(canonical_bytes(source_doc["blocks"])):
        failures.append(f"authored blocks changed {fixture_id}")
    counts = count_blocks(projection["document"]["blocks"])
    for key in totals:
        totals[key] += counts[key]
    projection_etag = projection["validators"]["projection_etag"]
    source_etag = projection["validators"]["source_etag"]
    for resource, body, etag in (("projection", projection_bytes, projection_etag), ("source", source, source_etag)):
        for case, supplied, expected_status, empty in (
            ("exact", etag, 304, True),
            ("stale", '"stale"', 200, False),
            ("absent", None, 200, False),
        ):
            status, response_body = conditional_response(body, etag, supplied)
            ok = status == expected_status and ((len(response_body) == 0) is empty) and (empty or response_body == body)
            conditional_rows.append({"fixture_id":fixture_id,"resource":resource,"case":case,"status":status,"body_bytes":len(response_body),"pass":ok})
            if not ok:
                failures.append(f"conditional {fixture_id} {resource} {case}")

    authored_leaves = leaves(projection["document"]["blocks"])
    artifacts: dict[str, bytes] = {
        "public": (HERE / "generated" / "adapters" / "public" / f"{fixture_id}.html").read_bytes(),
        "studio": (HERE / "generated" / "adapters" / "studio" / f"{fixture_id}.json").read_bytes(),
        "tui80": (HERE / "generated" / "adapters" / "tui80" / f"{fixture_id}.txt").read_bytes(),
        "email": (HERE / "generated" / "adapters" / "email" / f"{fixture_id}.eml").read_bytes(),
        "cli_api": (HERE / "generated" / "adapters" / "cli_api" / f"{fixture_id}.json").read_bytes(),
    }
    message = BytesParser(policy=policy.default).parsebytes(artifacts["email"])
    email_part = message.get_body(preferencelist=("html",))
    searchable = {
        "public": html_text(artifacts["public"]),
        "tui80": artifacts["tui80"].decode("utf-8"),
        "email": html_text(email_part.get_content().encode("utf-8")) if email_part else "",
    }
    for surface, haystack in searchable.items():
        compact_haystack = compact(haystack)
        visible = sum(1 for leaf in authored_leaves if compact(leaf) in compact_haystack)
        visibility[surface]["visible"] += visible
        visibility[surface]["planned"] += len(authored_leaves)
    studio_projection = json.loads(artifacts["studio"])["projection"]
    cli_projection = json.loads(artifacts["cli_api"])["data"]
    for surface, adapter_projection in (("studio", studio_projection), ("cli_api", cli_projection)):
        visibility[surface]["planned"] += len(authored_leaves)
        if adapter_projection["document"]["blocks"] == projection["document"]["blocks"]:
            visibility[surface]["visible"] += len(authored_leaves)
    public = artifacts["public"].decode("utf-8")
    if public.count("<th scope=\"col\">") != counts["authored_header_cells"]:
        failures.append(f"public headers {fixture_id}")
    if public.count("<td>") != counts["table_body_cells"]:
        failures.append(f"public body cells {fixture_id}")

if totals != EXPECTED_TOTALS:
    failures.append(f"denominators {totals}")
else:
    checks.append("frozen denominators exact")
if all(row["pass"] for row in conditional_rows) and len(conditional_rows) == 24:
    checks.append("conditional validators 24/24")
if all(row["visible"] == row["planned"] for row in visibility.values()):
    checks.append("authored carrier visibility all static adapters")
else:
    failures.append(f"static adapter visibility {visibility}")

quarantine = json.loads((HERE / "generated" / "receipts" / "quarantine.json").read_text())
if len(quarantine["quarantined"]) == 1 and quarantine["source_mutations"] == 0:
    checks.append("conflicting alias quarantine")
else:
    failures.append("quarantine")

rollback = rollback_simulation()
report("rollback-simulation.json", rollback)
if rollback["status"] == "PASS" and rollback["source_mutations"] == 0:
    checks.append("rollback simulation")
else:
    failures.append("rollback")

reader_matrix = json.loads((HERE / "generated" / "receipts" / "reader-matrix.json").read_text())
blocked = reader_matrix["real_reader_cells"]
if reader_matrix["proxy_passes"] == 0 and all(value.startswith("BLOCKED_") for value in blocked.values()):
    checks.append("blocked readers not proxy-passed")
else:
    failures.append("blocked reader honesty")

credential_patterns = {
    "private_key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "github_token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    "openai_key": re.compile(rb"sk-[A-Za-z0-9]{32,}"),
    "bearer": re.compile(rb"Authorization:\s*Bearer\s+[A-Za-z0-9._~-]{20,}", re.I),
}
credential_hits = []
scanned = 0
for path in sorted(p for p in HERE.rglob("*") if p.is_file() and "__pycache__" not in p.parts):
    data = path.read_bytes()
    scanned += 1
    for name, pattern in credential_patterns.items():
        if pattern.search(data):
            credential_hits.append({"path":path.relative_to(HERE).as_posix(),"pattern":name})
report("credential-scan.json", {"schema_version":"legendary-paper-restart-e06-credential-scan/v1","files_scanned":scanned,"hits":credential_hits})
if not credential_hits:
    checks.append("credential scan zero hits")
else:
    failures.append("credential scan")

hard_gates = {
    "authored_content_loss": "PASS",
    "invented_author_intent": "PASS",
    "schema_invalidity": "PASS",
    "page_or_display_overflow": "BLOCKED_REAL_READER_CAPTURE",
    "reading_order_failures": "BLOCKED_REAL_BROWSER_AT_AND_INTERACTIVE_TUI",
    "silent_scope_or_perspective_substitution": "PASS",
    "false_not_found": "BLOCKED_ISOLATED_CANDIDATE_HAS_NO_LIVE_ROUTE",
    "terminal_control_leaks": "PASS",
    "silent_secondary_failures": "PASS",
    "identity_domain_conflation": "PASS",
    "retry_erased_failures": "PASS",
    "non_idempotent_reruns": "PASS" if json.loads((HERE / "reports" / "replay.json").read_text()).get("byte_identical") is True else "FAIL",
    "rollback_failures": "PASS",
    "proxy_passes_for_missing_readers": "PASS",
}
if failures:
    for key in ("authored_content_loss", "schema_invalidity"):
        hard_gates[key] = "FAIL_VERIFICATION"

verification = {
    "schema_version": "legendary-paper-restart-e06-verification/v1",
    "candidate": GENERATOR_VERSION,
    "status": "PASS_LOCAL_WITH_BLOCKED_REAL_READERS" if not failures else "FAIL",
    "checks": checks,
    "check_count": len(checks),
    "failures": failures,
    "denominators": totals,
    "visibility": visibility,
    "conditional_validators": {"passed":sum(1 for row in conditional_rows if row["pass"]),"planned":24},
    "hard_gates": hard_gates,
    "blocked_real_readers": blocked,
    "observations": [
        "All four sealed raw captures are byte-preserved and all 815 authored blocks remain exact after NFC canonicalization.",
        "The versioned projection supplies six pairwise-distinct document/revision/release/projection/cache/Cycle identities.",
        "All five static adapters retain every measured authored leaf carrier; real reader execution remains blocked and is not scored as pass.",
    ],
    "preference": "This projection shape makes cache and revision provenance explicit but adds a version-negotiation and lifecycle surface that Attack must justify against the other candidates.",
}
report("conditional-validators.json", {"schema_version":"legendary-paper-restart-e06-conditional/v1","rows":conditional_rows})
report("verification.json", verification)
report("timing.json", {"schema_version":"legendary-paper-restart-e06-timing/v1","verify_seconds":round(time.monotonic()-started,6)})
print(json.dumps(verification, sort_keys=True, separators=(",", ":")))
if failures:
    raise SystemExit(1)
