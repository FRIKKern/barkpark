#!/usr/bin/env python3
"""Census of CONDITIONAL acceptance criteria across the Barkpark ledger.

A conditional criterion is one whose text OPENS with If / Once / When / Should
(case-insensitive).  Such a criterion can be honestly recorded as
not-applicable and then have its condition become TRUE later, under a
different row, with nothing in the ledger re-evaluating it
(task-conditional-criterion-goes-live-unwatched).

This script bounds that population.  It is deliberately re-runnable and
depends on nothing but python3 + the `bp` CLI.

    python3 scripts/ledger/conditional-criteria-census.py            # full sweep
    python3 scripts/ledger/conditional-criteria-census.py --json     # machine readable
    python3 scripts/ledger/conditional-criteria-census.py --cache DIR # reuse pages

TRUNCATION IS THE ENEMY.  `bp task ls` caps a page at 1000 rows and a
truncated sweep still prints a tidy answer, so this script:

  * pages with the KEYSET cursor (--cursor), never --offset, so a row that
    moves under us cannot be skipped past the 1000-row cap;
  * asserts pages * page_limit >= rows_returned, and that every page except
    the last returned a full page;
  * refuses to report unless the POSITIVE CONTROL row
    (task-33e6c69d4640ee5b, the measured incident) is present AND classified
    as carrying a conditional criterion.  A sweep that cannot see a row we
    KNOW is conditional is a broken instrument, not a small population.

The denominator is printed with every count.

THE REMEDY, DECIDED ON THIS MEASUREMENT (task-conditional-criterion-goes-live-unwatched)
---------------------------------------------------------------------------------------
Sweep of 2026-09-06, 8627 rows / 35490 criteria:

    (a) rows with >=1 conditional criterion   394 / 8627   (446 / 35490 criteria)
    (b) SUSPECT SET (open, every unmet
        criterion conditional)                  3 / 8627   = 0.035%
    (c) suspects whose condition is TRUE
        on origin/main today                    0 firm, 1 arguable

WHAT SHIPPED: this script, as a re-runnable SWEEP (`--fail-on-suspects` makes it
a gate), plus the authoring rule below.

WHAT WAS NOT BUILT, AND WHY, with the number as the reason:

  * A REQUIRED RE-CHECK TRIGGER ON `--miss`, mirroring how
    `stage --disposition parked` refuses without `--reopen-trigger`
    (api/lib/barkpark/tasks/stage.ex check_reopen_trigger/3, and the miss path
    at api/lib/barkpark/tasks/stamp.ex build_update/4 `{:miss, note}`).
    REJECTED. It taxes EVERY miss across 35490 criteria to serve a suspect set
    of 3, and — decisively — it would not have caught the measured incident.
    The condition there was "If the inline-annotation route is taken"; the
    route was taken under a DIFFERENT row's PR (#13736 / task-f44c1839cb28b0af).
    A trigger STRING recorded on the miss still needs a reader to evaluate it,
    so the mechanism would have bought a field, not a watcher.

  * A SERVER-SIDE WATCHER / re-evaluation queue. REJECTED for the same reason
    one level deeper: all three real conditions are PROSE about the world
    ("if a key is provisioned", "when multi-team lands", "if built"), and none
    is machine-decidable from the ledger or from origin/main. A watcher that
    cannot evaluate its own predicate is a queue that never drains.

  * ONLY the AUTHORING RULE, with no sweep. REJECTED: the incident's criterion
    was authored BEFORE any rule would exist, and 446 conditional criteria are
    already on the record. A rule is prospective; the sweep is retrospective,
    and the population that needs looking at is 3 rows — cheap enough to read
    by hand every time this runs.

THE AUTHORING RULE (prospective half): a criterion that opens with
If / Once / When / Should MUST name the OBSERVABLE that flips it — a file, a
symbol, a PR, a command that exits 0 — not just the route. "If the inline
route is taken" is unwatchable; "If `api/.sobelow-skips` no longer lists
frt.ex" is a grep.

CAVEAT ON (b), and it matters: the suspect heuristic has a structural false
positive. `scaffy-backlog-anchor-expansion-curated` carries an XOR PAIR —
"If built: ..." and "If closed instead: ..." — so it can never reach N of N by
construction, and no watcher can help it. 1 of the 3 suspects is noise.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

# The measured incident: criterion 3 (zero-based index 3) opens with "If ".
POSITIVE_CONTROL = "task-33e6c69d4640ee5b"

# Openers.  \b after the word so "Iffy"/"Whenever"/"Shoulder" do not match,
# and a leading quote/bullet/backtick is tolerated because criteria are prose.
CONDITIONAL_RE = re.compile(r'^[\s"\'`*\-—–(\[]*(if|once|when|should)\b', re.IGNORECASE)

# Lifecycle states that mean "this row is still on the hook".
OPEN_STATES = {"open", "blocked", "in_progress", "considering", "researching"}


def is_conditional(text: str) -> bool:
    return bool(CONDITIONAL_RE.match(text or ""))


def bp_page(cursor: str, limit: int, cache_dir: str | None, page_no: int) -> dict:
    """One page of `bp task ls`, optionally cached on disk for re-runs."""
    cache_path = None
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)
        cache_path = os.path.join(cache_dir, f"page-{page_no:03d}.json") if page_no else None
        if cache_path is None:
            cache_dir = None
        if page_no and os.path.exists(cache_path):
            with open(cache_path) as fh:
                return json.load(fh)

    env = dict(os.environ)
    # A stale BARKPARK_TOKEN in the environment shadows ~/.config/barkpark and
    # silently downgrades the read to tier=none, which looks like an empty ledger.
    env.pop("BARKPARK_TOKEN", None)
    argv = ["bp", "task", "ls", "--limit", str(limit), "--cursor", cursor, "-o", "json"]
    proc = subprocess.run(argv, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        sys.exit(f"FATAL: {' '.join(argv)} exited {proc.returncode}\n{proc.stderr[:2000]}")
    # bp may print warnings on stdout before the JSON body.
    start = proc.stdout.find("{")
    if start < 0:
        sys.exit(f"FATAL: no JSON in bp output:\n{proc.stdout[:2000]}")
    body = json.loads(proc.stdout[start:])
    if not body.get("ok"):
        sys.exit(f"FATAL: bp returned ok=false: {json.dumps(body)[:2000]}")
    if cache_path:
        with open(cache_path, "w") as fh:
            json.dump(body, fh)
    return body


def bp_get(doc_id: str) -> dict | None:
    """One row by id — used to RECOVER a row the keyset walk churned past."""
    env = dict(os.environ)
    env.pop("BARKPARK_TOKEN", None)
    proc = subprocess.run(
        ["bp", "task", "get", doc_id, "-o", "json"], capture_output=True, text=True, env=env
    )
    if proc.returncode != 0:
        return None
    start = proc.stdout.find("{")
    if start < 0:
        return None
    return (json.loads(proc.stdout[start:]) or {}).get("doc")


def sweep(limit: int, cache_dir: str | None, max_pages: int) -> tuple[list[dict], dict]:
    docs: list[dict] = []
    cursor = ""
    page_no = 0
    page_sizes: list[int] = []
    while True:
        page_no += 1
        if page_no > max_pages:
            sys.exit(f"FATAL: exceeded --max-pages {max_pages}; sweep would be truncated.")
        body = bp_page(cursor, limit, cache_dir, page_no)
        page = body.get("page", {})
        batch = body.get("docs") or []
        docs.extend(batch)
        page_sizes.append(len(batch))
        if not page.get("has_more"):
            break
        cursor = page.get("next_cursor") or ""
        if not cursor:
            sys.exit("FATAL: has_more=true but no next_cursor — sweep would silently truncate.")

    # ---- non-truncation assertions -------------------------------------
    assert len(page_sizes) * limit >= len(docs), (
        f"pages({len(page_sizes)}) * limit({limit}) < returned({len(docs)}) — impossible, parser is wrong"
    )
    for i, size in enumerate(page_sizes[:-1]):
        assert size == limit, (
            f"page {i + 1} returned {size} of {limit} but was not the last page — the stream truncated"
        )
    # CHURN, not a loop.  The keyset walks (updated_at, id) DESCENDING, and the
    # ledger is written to by other agents while we page.  A row touched
    # mid-sweep jumps to the FRONT of the ordering: if we already passed it we
    # see it twice (harmless — we keep the newest copy), and if we had not yet
    # reached it we can MISS it.  So we dedupe, count the churn, and then
    # reconcile against a fresh head page: any doc_id in the newest rows that
    # the sweep never saw is a churn-skip, and it is REPORTED rather than
    # silently absent.  A tidy answer over a truncated sweep is the failure
    # mode this whole block exists to refuse.
    seen: dict[str, dict] = {}
    dupes = 0
    for d in docs:
        did = d.get("doc_id")
        if did in seen:
            dupes += 1
        seen[did] = d
    deduped = list(seen.values())

    head = bp_page("", limit, None, 0)
    head_ids = {d.get("doc_id") for d in (head.get("docs") or [])}
    skipped = sorted(head_ids - set(seen))
    # RECOVER them rather than merely reporting them: a skipped row fetched by
    # id is a row the census counted.
    recovered = []
    for did in skipped:
        doc = bp_get(did)
        if doc:
            seen[did] = doc
            recovered.append(did)
    deduped = list(seen.values())

    return deduped, {
        "pages": len(page_sizes),
        "page_limit": limit,
        "page_sizes": page_sizes,
        "rows_returned": len(docs),
        "rows_unique": len(deduped),
        "churn_duplicates": dupes,
        "churn_skips": skipped,
        "churn_skips_recovered": recovered,
    }


def classify(docs: list[dict]) -> dict:
    total_rows = len(docs)
    rows_with_criteria = 0
    total_criteria = 0
    conditional_criteria = 0
    rows_with_conditional: list[dict] = []
    suspect: list[dict] = []
    conditional_by_opener = {"if": 0, "once": 0, "when": 0, "should": 0}

    for doc in docs:
        crits = ((doc.get("content") or {}).get("acceptance_criteria")) or []
        if not isinstance(crits, list) or not crits:
            continue
        rows_with_criteria += 1
        total_criteria += len(crits)

        cond_idx, unmet_idx = [], []
        for i, c in enumerate(crits):
            if not isinstance(c, dict):
                continue
            text = c.get("criterion") or ""
            m = CONDITIONAL_RE.match(text)
            if m:
                cond_idx.append(i)
                conditional_criteria += 1
                conditional_by_opener[m.group(1).lower()] += 1
            if not c.get("met"):
                unmet_idx.append(i)

        if not cond_idx:
            continue

        status = doc.get("lifecycle_status") or ""
        row = {
            "doc_id": doc.get("doc_id"),
            "lifecycle_status": status,
            "title": (doc.get("title") or "")[:110],
            "criteria_total": len(crits),
            "conditional_idx": cond_idx,
            "unmet_idx": unmet_idx,
            "unmet_conditional_idx": [i for i in unmet_idx if i in cond_idx],
            "updated_at": doc.get("updated_at"),
            "assignee": doc.get("assignee"),
        }
        rows_with_conditional.append(row)

        # THE SUSPECT SET: still open, and every remaining unmet criterion is
        # a conditional one.  Each of these is either genuinely blocked, or
        # silently satisfiable, and nothing in the ledger tells them apart.
        if status in OPEN_STATES and unmet_idx and all(i in cond_idx for i in unmet_idx):
            suspect.append(row)

    return {
        "total_rows": total_rows,
        "rows_with_criteria": rows_with_criteria,
        "total_criteria": total_criteria,
        "conditional_criteria": conditional_criteria,
        "conditional_by_opener": conditional_by_opener,
        "rows_with_conditional": rows_with_conditional,
        "suspect": suspect,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=1000, help="rows per page (bp caps at 1000)")
    ap.add_argument("--cache", default=None, help="directory to cache/reuse raw pages")
    ap.add_argument("--max-pages", type=int, default=100)
    ap.add_argument("--json", action="store_true", help="emit the full result as JSON")
    ap.add_argument("--list-suspects", action="store_true", help="print every suspect row")
    ap.add_argument(
        "--no-control",
        action="store_true",
        help="skip the positive-control assertion (DEBUG ONLY — a sweep without it can report a tidy zero)",
    )
    ap.add_argument("--selftest", action="store_true", help="check the classifier against known cases and exit")
    ap.add_argument("--fail-on-suspects", action="store_true", help="exit 1 when the suspect set is non-empty (sweep-as-gate)")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    docs, sweep_meta = sweep(args.limit, args.cache, args.max_pages)
    res = classify(docs)
    res["sweep"] = sweep_meta

    # ---- positive control ---------------------------------------------
    control = next((r for r in res["rows_with_conditional"] if r["doc_id"] == POSITIVE_CONTROL), None)
    control_seen = any(d.get("doc_id") == POSITIVE_CONTROL for d in docs)
    res["control"] = {"doc_id": POSITIVE_CONTROL, "row_seen": control_seen, "classified_conditional": bool(control)}
    if not args.no_control:
        if not control_seen:
            sys.exit(
                f"FATAL: positive control {POSITIVE_CONTROL} not in the sweep "
                f"({len(docs)} rows over {sweep_meta['pages']} pages) — the sweep is truncated."
            )
        if not control:
            sys.exit(
                f"FATAL: positive control {POSITIVE_CONTROL} was swept but NOT classified as "
                "carrying a conditional criterion — the classifier is blind."
            )

    if args.json:
        print(json.dumps(res, indent=1))
        return 0

    n = res["total_rows"]
    print("CONDITIONAL ACCEPTANCE-CRITERION CENSUS")
    print(f"  query: bp task ls --limit {args.limit} --cursor <keyset> -o json  (walked to has_more=false)")
    print(f"  opener regex: {CONDITIONAL_RE.pattern}")
    print()
    print(f"  DENOMINATOR: {n} unique task rows over {sweep_meta['pages']} pages "
          f"(page sizes {sweep_meta['page_sizes']}, cap {args.limit}; "
          f"{sweep_meta['rows_returned']} returned, {sweep_meta['churn_duplicates']} churn duplicates)")
    print(f"  churn skips found by the head-page reconciliation: {len(sweep_meta['churn_skips'])} "
          f"{sweep_meta['churn_skips'][:10]}")
    print(f"  rows carrying >=1 acceptance criterion : {res['rows_with_criteria']} / {n}")
    print(f"  acceptance criteria in total          : {res['total_criteria']}")
    print()
    print(f"(a) rows with >=1 CONDITIONAL criterion  : {len(res['rows_with_conditional'])} / {n} rows"
          f"  ({res['conditional_criteria']} / {res['total_criteria']} criteria)")
    print(f"      by opener: {res['conditional_by_opener']}")
    print(f"(b) SUSPECT SET (open, and every unmet")
    print(f"    criterion is conditional)           : {len(res['suspect'])} / {len(res['rows_with_conditional'])} conditional rows")
    print(f"(c) suspects whose condition is TRUE on origin/main today: adjudicated by hand — see the list below;")
    print(f"    the condition lives in PROSE, which is precisely why no mechanism can read it.")
    print()
    print(f"  positive control {POSITIVE_CONTROL}: seen={res['control']['row_seen']} "
          f"classified={res['control']['classified_conditional']}"
          + (f" unmet_idx={control['unmet_idx']} conditional_idx={control['conditional_idx']}" if control else ""))
    if args.list_suspects or len(res["suspect"]) <= 40:
        print()
        print("  SUSPECTS:")
        for r in res["suspect"]:
            print(f"    {r['doc_id']}  [{r['lifecycle_status']}]  unmet={r['unmet_idx']} of {r['criteria_total']}"
                  f"  cond={r['conditional_idx']}  {r['title']}")
    if args.fail_on_suspects and res["suspect"]:
        print()
        print(f"FAIL: {len(res['suspect'])} row(s) sit on a conditional criterion nobody is watching.")
        return 1
    return 0


# ---------------------------------------------------------------------------
# SELFTEST.  A classifier with no test of its own is exactly the blind
# instrument this row is about: it would print a tidy 0 and we would believe it.
# Each POSITIVE is a real criterion shape from the ledger; each NEGATIVE is a
# shape that must NOT be swept in, because a false positive inflates the
# population and buys a mechanism nobody needs.
SELFTEST_POSITIVE = [
    "If the inline-annotation route is taken: prove by MUTATION that each annotation binds",
    "If a key is provisioned: 12 count_tokens results (6 payloads x 2 pinned models) committed",
    "When multi-team membership exists, removing a user from one team revokes only that team",
    "Once the migration lands, the backfill is proven on a real row",
    "Should the gate stay red, the rollback is exercised",
    "  if the route is taken: prove it",          # leading whitespace
    '"If closed instead: the closing evidence names the recoverable-set size',  # leading quote
    "- If built: expansion covers exactly the curated allowlist",  # bullet
]
SELFTEST_NEGATIVE = [
    "The PR merges to main and the Security gate aggregator is green on a main head after it.",
    "Iffy wording is not a conditional and must not be counted.",
    "Whenever-style prose is a different word and must not match.",   # \b stops "when" here
    "Shoulder-tapping the lead is not a condition.",
    "Verify that if the route is taken the annotation binds — the conditional is not the OPENER.",
    "",
]


def selftest() -> int:
    bad = []
    for t in SELFTEST_POSITIVE:
        if not is_conditional(t):
            bad.append(("expected CONDITIONAL", t))
    for t in SELFTEST_NEGATIVE:
        if is_conditional(t):
            bad.append(("expected PLAIN", t))
    for why, t in bad:
        print(f"FAIL {why}: {t[:90]!r}")
    print(f"selftest: {len(SELFTEST_POSITIVE)} positives, {len(SELFTEST_NEGATIVE)} negatives, {len(bad)} failures")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
