#!/usr/bin/env python3
"""THE WITHDRAWN-BUT-MET GUARD (charter D745, cloud-console-hardening wave 62).

WHAT IT FINDS, in one sentence: a task criterion the ledger still flags
``met: true`` while that criterion's own evidence text announces that the proof
has been withdrawn — so every board counts it as proven and the only thing
standing between a lead and a false close is somebody reading a paragraph of
prose inside an evidence string.

WHY THE CLASS EXISTED. Until ``bp task stamp --withdraw`` shipped, the write
surface offered ``--met`` (raise) and ``--miss`` (pin) and nothing that could
LOWER a met flag. A reviewer who refuted a stamped proof therefore had exactly
one place to put the correction — the evidence field of the criterion itself —
and wrote things like::

    [WITHDRAWN BY WAVE REVIEW 2026-08-09 — NOT MET ON THE FINAL BRANCH …
     The met flag above could not be un-flipped: the ledger refuses a
     met:true -> met:false patch, so read this evidence, not the flag.]

The flag stayed up. The board stayed wrong. This script is the instrument that
makes that state impossible to hold quietly: it is a query, not a reading.

THE DETECTOR, and its honest limits. It looks for a SELF-WITHDRAWAL
ANNOTATION: a bracketed, upper-case ``WITHDRAWN`` / ``RETRACTED`` / ``NOT MET``
/ ``WITHDRAWAL`` block that is either PREPENDED to the evidence (starts at
offset 0) or APPENDED to it (ends at the end of the evidence). That
prepended-or-appended rule is the whole discrimination, and it is load-bearing:
an ANNOTATION is bolted onto the front or the back of a proof, while a
QUOTATION of somebody else's retraction sits in the MIDDLE of a sentence.
Measured over the live ledger on 2026-09-01 — 8,119 rows, 33,761 criteria,
22,450 of them met — the rule returns 12 findings across 2 rows with zero false
positives, where a bare "does the evidence contain WITHDRAWN" match returns 220
and a bare bracket match returns 14 (2 of them quotations).

It keys on a CONVENTION, and says so. The convention is what reviewers actually
wrote when the verb did not exist; a reviewer today should use ``--withdraw``,
which lowers the flag so no detector is needed. This guard is therefore aimed at
the LEGACY population and at any relapse into prose — it is not, and cannot be,
a proof that no criterion anywhere is secretly wrong.

USAGE
    python3 scripts/withdrawn_but_met.py --dump <file.json> [--json]
    python3 scripts/withdrawn_but_met.py --live [--limit 200] [--json]
    python3 scripts/withdrawn_but_met.py --selftest

    --dump      a JSON file holding either {"docs": [...]}, a bare [...] of task
                rows, or several such objects concatenated (one per page).
    --live      page the whole ledger through `bp task ls` and scan that.
                `bp task ls --all` 500s on the current corpus, so this pages
                explicitly and REFUSES to report a clean result if any page
                failed — a census with a hole in it is not a census.
    --selftest  run the detector against built-in fixtures, including the
                NON-VACUITY arm: it asserts the guard actually REDS on a
                poisoned row, so a detector that silently stopped matching
                fails here instead of reporting a reassuring zero.

EXIT CODES
    0  no withdrawn-but-met criteria found (and, under --live, every page read)
    1  findings — each printed with its row, index, and the annotation
    2  the scan could not be completed (unreadable dump, a failed live page)
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any, Iterable, NamedTuple

# The markers a reviewer reaches for when they cannot lower the flag. Upper-case
# ONLY and word-bounded: lower-case "withdrawn"/"superseded" is ordinary prose
# and appears in hundreds of legitimate evidence strings.
_MARKERS = r"WITHDRAWN|RETRACTED|NOT MET|WITHDRAWAL"

# A bracketed annotation block: "[" then a marker, then anything but a closing
# bracket. The closing bracket is optional so a truncated annotation (the
# evidence hit a length ceiling mid-sentence) is still caught rather than
# silently skipped — a truncated withdrawal is still a withdrawal.
_ANNOTATION = re.compile(r"\[\s*(?:%s)\b[^\]]*\]?" % _MARKERS)


class Finding(NamedTuple):
    """One criterion the ledger flags met while its evidence retracts itself."""

    doc_id: str
    index: int
    lifecycle: str
    criterion: str
    annotation: str
    evidence_len: int

    def render(self) -> str:
        return (
            f"  {self.doc_id}  criterion[{self.index}]  (lifecycle: {self.lifecycle})\n"
            f"    criterion : {_clip(self.criterion, 100)}\n"
            f"    withdrawn : {_clip(self.annotation, 220)}\n"
            f"    …yet met  : true   (evidence {self.evidence_len} bytes)"
        )


def _clip(s: str, n: int) -> str:
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def self_withdrawal_annotation(evidence: str) -> str | None:
    """Return the self-withdrawal annotation in ``evidence``, or None.

    PREPENDED or APPENDED only. A marker block in the middle of the text is a
    quotation of some other retraction — of a code comment, of a sibling row's
    history — and reporting it would train readers to skim this guard's output,
    which is how a guard stops being read at all.
    """
    if not isinstance(evidence, str) or not evidence.strip():
        return None
    text = evidence.strip()
    for m in _ANNOTATION.finditer(text):
        prepended = m.start() == 0
        appended = m.end() == len(text)
        if prepended or appended:
            return m.group(0)
    return None


def scan_rows(rows: Iterable[dict[str, Any]]) -> tuple[list[Finding], dict[str, int]]:
    """Scan task rows; return (findings, counts). Counts make the denominator
    visible, because a zero over an empty scan is not the same answer as a zero
    over the whole ledger and must never print the same way."""
    findings: list[Finding] = []
    counts = {"rows": 0, "rows_with_criteria": 0, "criteria": 0, "met": 0}
    for row in rows:
        if not isinstance(row, dict):
            continue
        counts["rows"] += 1
        content = row.get("content")
        criteria = content.get("acceptance_criteria") if isinstance(content, dict) else None
        if not isinstance(criteria, list):
            continue
        counts["rows_with_criteria"] += 1
        doc_id = row.get("doc_id") or row.get("id") or "<unnamed row>"
        lifecycle = row.get("lifecycle_status") or "?"
        for index, entry in enumerate(criteria):
            if not isinstance(entry, dict):
                continue
            counts["criteria"] += 1
            # `met` is met ONLY when it is exactly boolean true — the same
            # tolerance the server applies (Barkpark.Tasks.Criteria.met?/1), so
            # this guard and the progress counter can never disagree about what
            # a met row is.
            if entry.get("met") is not True:
                continue
            counts["met"] += 1
            evidence = entry.get("evidence") or ""
            annotation = self_withdrawal_annotation(evidence)
            if annotation is None:
                continue
            findings.append(
                Finding(
                    doc_id=str(doc_id),
                    index=index,
                    lifecycle=str(lifecycle),
                    criterion=str(entry.get("criterion") or ""),
                    annotation=annotation,
                    evidence_len=len(evidence),
                )
            )
    return findings, counts


def rows_from_json_text(text: str) -> list[dict[str, Any]]:
    """Read task rows out of a dump. Accepts a single object, a bare list, or
    several concatenated JSON documents (what a paging loop naturally writes),
    and de-duplicates by doc_id so overlapping pages cannot inflate a count."""
    decoder = json.JSONDecoder()
    rows: list[dict[str, Any]] = []
    idx, n = 0, len(text)
    while idx < n:
        while idx < n and text[idx].isspace():
            idx += 1
        if idx >= n:
            break
        obj, idx = decoder.raw_decode(text, idx)
        if isinstance(obj, list):
            rows.extend(x for x in obj if isinstance(x, dict))
        elif isinstance(obj, dict):
            page = obj.get("docs") or obj.get("rows") or obj.get("tasks")
            if isinstance(page, list):
                rows.extend(x for x in page if isinstance(x, dict))
            elif "content" in obj or "doc_id" in obj:
                rows.append(obj)
            elif isinstance(obj.get("doc"), dict):
                rows.append(obj["doc"])
    seen: dict[str, dict[str, Any]] = {}
    for r in rows:
        seen[str(r.get("doc_id") or r.get("id") or id(r))] = r
    return list(seen.values())


def fetch_live_rows(page: int) -> tuple[list[dict[str, Any]], list[str]]:
    """Page the whole ledger through `bp task ls`. Returns (rows, errors).

    `bp task ls --all` answers a 500 on the current corpus, so the pages are
    explicit — and every failed page is REPORTED, never skipped. A census that
    silently drops the page containing the finding is worse than no census.
    """
    rows: list[dict[str, Any]] = []
    errors: list[str] = []
    offset = 0
    while True:
        cmd = ["bp", "task", "ls", "--limit", str(page), "--offset", str(offset), "-o", "json"]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        # bp prints an advisory line before the envelope when a page fills the
        # limit exactly; the envelope is always the last non-empty line.
        lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
        if not lines:
            errors.append(f"offset {offset}: no output (rc={proc.returncode})")
            break
        try:
            body = json.loads(lines[-1])
        except json.JSONDecodeError as exc:
            errors.append(f"offset {offset}: unparseable response ({exc})")
            break
        if not body.get("ok", True) or "docs" not in body:
            errors.append(f"offset {offset}: {json.dumps(body.get('error') or body)[:200]}")
            break
        docs = body.get("docs") or []
        rows.extend(d for d in docs if isinstance(d, dict))
        if len(docs) < page:
            break
        offset += page
    return rows, errors


# ─── SELFTEST ──────────────────────────────────────────────────────────────
#
# Two arms, and the second is the one that matters. A guard that has quietly
# stopped matching reports a clean ledger, which reads exactly like good news.
# So the selftest asserts the detector REDS on a poisoned fixture as well as
# staying quiet on a clean one — the same non-vacuity discipline the criteria
# themselves are held to.

_POISONED = {
    "docs": [
        {
            "doc_id": "fixture-withdrawn-prepended",
            "lifecycle_status": "done",
            "content": {
                "acceptance_criteria": [
                    {
                        "criterion": "the worker only stamps on a 202",
                        "met": True,
                        "evidence": (
                            "[WITHDRAWN BY WAVE REVIEW 2026-08-09 — NOT MET ON THE FINAL "
                            "BRANCH. The met flag above could not be un-flipped: the ledger "
                            "refuses a met:true -> met:false patch, so read this evidence, "
                            "not the flag.] The original proof followed here."
                        ),
                    }
                ]
            },
        },
        {
            "doc_id": "fixture-withdrawn-appended",
            "lifecycle_status": "cancelled",
            "content": {
                "acceptance_criteria": [
                    {
                        "criterion": "a cross-tenant revoke is refused",
                        "met": True,
                        "evidence": (
                            "links.ex revoke/2 filters on workspace_id; 19 tests, 0 failures. "
                            "[RETRACTED 2026-08-19, wave-1 Decide: the proof rode a banned "
                            "predicate. The met flag is left standing only because the server "
                            "refuses to clear a stamped proof.]"
                        ),
                    }
                ]
            },
        },
    ]
}

_CLEAN = {
    "docs": [
        {
            # An ordinary proven criterion.
            "doc_id": "fixture-ordinary",
            "lifecycle_status": "done",
            "content": {
                "acceptance_criteria": [
                    {"criterion": "gate green", "met": True, "evidence": "42 tests, 0 failures"}
                ]
            },
        },
        {
            # A QUOTATION of somebody else's retraction, mid-sentence. The work
            # this row did WAS retracting a false comment in the codebase; its
            # own proof stands. Reporting it would be a false positive, and a
            # guard that cries wolf stops being read.
            "doc_id": "fixture-quotes-a-retraction",
            "lifecycle_status": "done",
            "content": {
                "acceptance_criteria": [
                    {
                        "criterion": "the false comment is retracted in both files",
                        "met": True,
                        "evidence": (
                            "Pinned by the four lines now in required-checks.test.sh: "
                            "'…:4567 READ 2026-08-06: same shape in the debrief — \"as measured "
                            "then\", inline [RETRACTED … protection is live]; kept as reasoning, "
                            "not as a claim' — all four re-read at their live line."
                        ),
                    }
                ]
            },
        },
        {
            # The verb doing its job: met is already FALSE and the withdrawal is
            # a first-class record. There is nothing here to report — this is
            # what the ledger looks like once the fix is used.
            "doc_id": "fixture-properly-withdrawn",
            "lifecycle_status": "done",
            "content": {
                "acceptance_criteria": [
                    {
                        "criterion": "the worker only stamps on a 202",
                        "met": False,
                        "evidence": "the superseded proof, kept readable",
                        "withdrawals": [
                            {
                                "note": "review: the gate ran on the wrong branch",
                                "worker": "wave-review",
                                "ts": "2026-09-01T00:00:00Z",
                                "superseded_evidence": "the superseded proof, kept readable",
                            }
                        ],
                    }
                ]
            },
        },
    ]
}


def selftest() -> int:
    failures: list[str] = []

    poisoned, counts = scan_rows(rows_from_json_text(json.dumps(_POISONED)))
    # ARM 1 — NON-VACUITY. The guard must RED on the shapes actually found on
    # the live ledger: one prepended annotation, one appended.
    if len(poisoned) != 2:
        failures.append(f"poisoned fixture: expected 2 findings, got {len(poisoned)}")
    found = {f.doc_id for f in poisoned}
    for want in ("fixture-withdrawn-prepended", "fixture-withdrawn-appended"):
        if want not in found:
            failures.append(f"poisoned fixture: {want} was NOT caught")
    if counts["met"] != 2:
        failures.append(f"poisoned fixture: expected 2 met criteria scanned, got {counts['met']}")

    # ARM 2 — NO FALSE POSITIVES. An ordinary proof, a quotation of somebody
    # else's retraction, and a properly withdrawn row must all stay quiet.
    clean, clean_counts = scan_rows(rows_from_json_text(json.dumps(_CLEAN)))
    if clean:
        failures.append(
            "clean fixture produced findings (false positives): "
            + ", ".join(f"{f.doc_id}[{f.index}]" for f in clean)
        )
    if clean_counts["criteria"] != 3:
        failures.append(
            f"clean fixture: expected 3 criteria scanned, got {clean_counts['criteria']} "
            "— a guard that scans nothing reports a reassuring zero"
        )

    if failures:
        print("SELFTEST FAILED")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("SELFTEST PASSED")
    print("  ✓ reds on a prepended [WITHDRAWN …] annotation over met:true")
    print("  ✓ reds on an appended [RETRACTED …] annotation over met:true")
    print("  ✓ quiet on an ordinary proof, on a QUOTED retraction, and on a")
    print("    properly withdrawn row (met already false, withdrawals[] present)")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="withdrawn_but_met.py",
        description="Find criteria the ledger flags met while their own evidence withdraws the proof.",
    )
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--dump", help="JSON file of task rows to scan")
    src.add_argument("--live", action="store_true", help="page the live ledger via `bp task ls`")
    src.add_argument("--selftest", action="store_true", help="run the built-in fixtures")
    ap.add_argument("--limit", type=int, default=200, help="page size for --live (default 200)")
    ap.add_argument("--json", action="store_true", help="emit findings as JSON")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    errors: list[str] = []
    if args.live:
        rows, errors = fetch_live_rows(args.limit)
    else:
        try:
            with open(args.dump, encoding="utf-8") as fh:
                rows = rows_from_json_text(fh.read())
        except (OSError, json.JSONDecodeError) as exc:
            print(f"could not read {args.dump}: {exc}", file=sys.stderr)
            return 2

    findings, counts = scan_rows(rows)

    if args.json:
        print(
            json.dumps(
                {
                    "ok": not findings and not errors,
                    "counts": counts,
                    "errors": errors,
                    "findings": [f._asdict() for f in findings],
                },
                indent=2,
            )
        )
    else:
        print(
            "scanned %d rows (%d with criteria), %d criteria, %d flagged met"
            % (counts["rows"], counts["rows_with_criteria"], counts["criteria"], counts["met"])
        )
        if findings:
            print(f"\nWITHDRAWN BUT STILL FLAGGED MET — {len(findings)} criteria:\n")
            for f in findings:
                print(f.render())
                print()
            print(
                "Each of these reads MET on every board while its own evidence says it is not.\n"
                "The fix is the first-class verb, which lowers the flag and signs the correction:\n"
                "  bp task stamp <id> <worker> <epoch> --criterion <N> --withdraw \\\n"
                "    --criterion-text \"<the criterion's exact stored wording>\" \\\n"
                "    --note \"<why review refuted it>\" --observed-rev <rev> --yes\n"
                "(--observed-rev is required when the row is not in_progress: a sealed row has\n"
                " no live lease to fence against, so the rev you read is the fence instead.)"
            )
        else:
            print("\nno withdrawn-but-met criteria found")

    if errors:
        print("\nSCAN INCOMPLETE — these pages did not read, so a clean result is NOT earned:", file=sys.stderr)
        for e in errors:
            print(f"  ! {e}", file=sys.stderr)
        return 2
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
