#!/usr/bin/env python3
"""One sweep, one denominator: every claim-map shape counted over ONE row set.

Supersedes the three separate measurements consolidated into the ledger row
`pds-bl-null-expiry-claims-repo-wide` (and the ad-hoc sweep2.py that measured
only the lifecycle=open-with-live-worker shape).

WHAT `expired_at` ACTUALLY IS -- read this before interpreting any count.
`content.claim.expired_at` is NOT a lease deadline. It is a REAP RECEIPT: the
only writer in the tree is Barkpark.Tasks.TtlSweeper.apply_reap/1, which stamps
it at the moment the sweeper takes a lapsed lease back (alongside
`previous_worker`, `worker: nil`, and an epoch bump). The live lease deadline is
computed, never stored: TtlSweeper.expired_candidates/2 compares
`content.claim.ts_iso` against `now - task_lease_ttl_seconds` (default 2700s).
So `expired_at: null` on a live claim is the NORMAL shape of a claim that has
simply never been reaped -- it does not mean "a lease that can never lapse".

PROVEN BY ATTEMPT 2026-09-06: `bp task claim scaffy-backlog-ensure-cli-flag
cli-w1-probe` (a row in the null-expiry set, worker null since 2026-07-18)
SUCCEEDED, epoch 2 -> 3. The CLI answered `lease: epoch=3
expires_at=2026-09-06T09:29:10Z lease=45min` -- an expiry it COMPUTED for
display. The resulting stored claim map is
{epoch, ts_iso, worker, work_digest, work_field_digests}: no expired_at key at
all. A healthy live claim has never had one.

Usage:  python3 scripts/ledger/claim-shape-census.py [--limit 1000] [--sleep 1]
Deps:   python3 + the `bp` CLI on PATH. No network access beyond bp.
"""

import argparse
import collections
import json
import os
import subprocess
import sys
import time

# Rows we KNOW exist -- the positive control. A sweep that reports zero
# without proving it can see a row it was told about is not a measurement.
POSITIVE_CONTROLS = [
    "pds-bl-null-expiry-claims-repo-wide",
    "pds-bl-repull-into-populated-target-500",
]

# MEASURED 2026-09-06: the ledger's terminal lifecycle value is "done", NOT
# "closed". A census that spells it "closed" silently counts 5,793 finished
# rows as OPEN and reports a 5,420-row "third shape" that is just history.
# Live values seen in one full sweep: done, open, cancelled, considering,
# in_progress, blocked.
CLOSED_LIFECYCLES = {"done", "cancelled", "canceled", "closed"}


def get(claim, key):
    """Absent key and explicit null are the same thing for every shape here."""
    if not isinstance(claim, dict):
        return None
    return claim.get(key)


class SweepRefusal(SystemExit):
    """A named refusal. A FAILED page is never the end of the board.

    Every arm below used to be a silent `break` or a swallow: the walk stopped
    early and the census printed a SMALLER DENOMINATOR with exit 0. The read
    path underneath (GET /v1/data/query/production/task) is the one that 500'd
    under concurrent write load on 2026-07-30; the caller-side rule is that a
    page which did not PROVE it is the last one ends the run, not the loop.
    """

    def __init__(self, offset, msg):
        super().__init__(f"FATAL: sweep REFUSED at offset {offset}: {msg}")


def fetch_all(limit, sleep):
    """Page `bp task ls` to exhaustion, dedup by doc_id -- or refuse.

    bp can print a WARNING on stdout before the JSON, so only lines starting
    with '{' are candidates and the LAST one is the payload.

    STRIDE: the offset advances by the rows the page ACTUALLY DELIVERED, never
    by the requested `--limit`. The server caps a page at 1000 rows
    (query_controller.ex: `min(1000)`), so `--limit 2000` with `offset += limit`
    asks for 2000, is served 1000, and then jumps to offset 2000 -- SKIPPING
    1000 rows with no error at all. Same defect class as the terminator.
    """
    env = dict(os.environ)
    env.pop("BARKPARK_TOKEN", None)  # a stale env token shadows config.json
    rows, pages, offset, returned_total = {}, 0, 0, 0
    while True:
        p = subprocess.run(
            ["bp", "task", "ls", "--limit", str(limit), "--offset", str(offset), "-o", "json"],
            capture_output=True, text=True, env=env,
        )
        if p.returncode != 0:
            raise SweepRefusal(offset, f"bp exited {p.returncode}; stderr={p.stderr[:400]}")
        cands = [l for l in p.stdout.splitlines() if l.startswith("{")]
        if not cands:
            raise SweepRefusal(offset, f"no JSON on stdout; rc={p.returncode} "
                                       f"stderr={p.stderr[:400]}")
        try:
            d = json.loads(cands[-1])
        except ValueError as exc:
            raise SweepRefusal(offset, f"stdout line is not JSON: {exc}")
        # A `{"ok": false, "error": ...}` failure PARSES CLEANLY, carries no
        # `docs` and no `page`, and reads as an empty last page to any caller
        # that only asks "did it parse?".
        if d.get("ok") is False:
            raise SweepRefusal(offset, f"bp returned ok=false: {json.dumps(d)[:400]}")
        docs = d.get("docs")
        if not isinstance(docs, list):
            raise SweepRefusal(offset, f"no `docs` list in the body; keys={sorted(d)[:12]}")
        page = d.get("page")
        if not isinstance(page, dict) or "has_more" not in page:
            raise SweepRefusal(offset, "the body carries no `page.has_more` -- nothing "
                                       "proves this page is the last one, and a short "
                                       "page is not a proof")
        pages += 1
        returned_total += len(docs)
        for doc in docs:
            rows[doc["doc_id"]] = doc
        has_more = page.get("has_more")
        print(f"  page {pages}: offset={offset} returned={len(docs)} "
              f"has_more={has_more} unique_so_far={len(rows)}", file=sys.stderr)
        if not has_more:
            break
        if not docs:
            raise SweepRefusal(offset, "has_more=true but the page delivered 0 rows -- "
                                       "advancing would spin, breaking would truncate")
        offset += len(docs)
        time.sleep(sleep)
    return rows, pages, returned_total


def selftest() -> int:
    """PINS fetch_all. No network, no bp, no credential: subprocess.run is
    stubbed, so every arm drives the REAL pager. Three controls, so a pager that
    refused everything could not score 100%."""
    import types

    class _P:
        def __init__(self, rc, out, err=""):
            self.returncode, self.stdout, self.stderr = rc, out, err

    def page(n, offset, has_more, ok=True):
        body = {"docs": [{"doc_id": f"d{offset + i}", "claim": {}} for i in range(n)],
                "page": {"has_more": has_more}}
        if not ok:
            body = {"ok": False, "error": "internal_error"}
        return _P(0, json.dumps(body) + "\n")

    real_run = subprocess.run
    bad = []

    def arm(name, want, script, limit=2):
        seq, seen = list(script), {"argv": []}

        def fake(argv, **kw):
            seen["argv"].append(argv)
            i = len(seen["argv"]) - 1
            return seq[min(i, len(seq) - 1)]

        subprocess.run = fake
        try:
            rows, pages, total = fetch_all(limit, 0)
            got, ok = f"rows={len(rows)} pages={pages} total={total}", (want == "OK")
        except SystemExit as exc:
            got, ok = str(exc).splitlines()[0], (want != "OK" and want in str(exc))
        finally:
            subprocess.run = real_run
        print(f"  {'ok  ' if ok else 'FAIL'}  {name:<46} {got[:130]}")
        if not ok:
            bad.append(name)
        return seen["argv"]

    print("claim-shape-census selftest -- fetch_all against a stubbed bp")
    arm("control: two pages, has_more terminates", "OK",
        [page(2, 0, True), page(1, 2, False)])
    arm("control: single empty board", "OK", [page(0, 0, False)])
    arm("control: bp warning line before JSON", "OK",
        [_P(0, "WARNING: bp is behind\n" + page(1, 0, False).stdout)])

    arm("MUTATION: bp exits non-zero", "bp exited 1",
        [page(2, 0, True), _P(1, "", "connection refused")])
    arm("MUTATION: 200-shaped ok=false body", "ok=false",
        [page(2, 0, True), page(0, 2, False, ok=False)])
    arm("MUTATION: no JSON on stdout", "no JSON on stdout",
        [page(2, 0, True), _P(0, "Internal Server Error\n")])
    arm("MUTATION: body carries no page.has_more", "no `page.has_more`",
        [_P(0, json.dumps({"docs": []}))])
    arm("MUTATION: docs is not a list", "no `docs` list",
        [_P(0, json.dumps({"docs": None, "page": {"has_more": False}}))])
    arm("MUTATION: has_more=true with 0 rows", "delivered 0 rows",
        [page(2, 0, True), page(0, 2, True)])

    # STRIDE: the server caps a page at 1000, so a --limit above the cap must
    # advance by the rows DELIVERED. `offset += limit` skipped the difference.
    argv = arm("STRIDE: --limit 2000 served 1000-row pages", "OK",
               [page(3, 0, True), page(3, 3, True), page(1, 6, False)], limit=2000)
    offsets = [a[a.index("--offset") + 1] for a in argv]
    if offsets != ["0", "3", "6"]:
        bad.append("stride offsets")
        print(f"  FAIL  {'stride offsets':<46} {offsets} != ['0', '3', '6']")
    else:
        print(f"  ok    {'stride offsets advance by rows delivered':<46} {offsets}")

    print(f"claim-shape-census selftest: {len(bad)} failures")
    return 1 if bad else 0


def pct(n, d):
    return f"{n}/{d}" + (f" ({100.0 * n / d:.1f}%)" if d else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=1000)
    ap.add_argument("--sleep", type=float, default=1.0)
    ap.add_argument("--dump", help="write the raw deduped row set here as JSON")
    ap.add_argument("--from-dump", help="re-analyse a previous --dump instead of re-paging")
    ap.add_argument("--selftest", action="store_true",
                    help="pin the pager's refusals against a stubbed bp and exit")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.from_dump:
        rows = json.load(open(args.from_dump))
        pages, returned_total = 0, len(rows)
        print(f"RE-ANALYSING dump {args.from_dump} ({len(rows)} rows)", file=sys.stderr)
    else:
        print("PAGING bp task ls ...", file=sys.stderr)
        rows, pages, returned_total = fetch_all(args.limit, args.sleep)
    if args.dump:
        with open(args.dump, "w") as fh:
            json.dump(rows, fh)

    N = len(rows)
    print("=" * 78)
    print("CLAIM-SHAPE CENSUS -- one sweep, one row set, one denominator")
    print("=" * 78)
    print(f"PAGES fetched                : {pages} (page size {args.limit})")
    print(f"ROWS returned across pages   : {returned_total}")
    print(f"DENOMINATOR (unique doc_id)  : {N}")
    if args.from_dump:
        print("coverage check               : n/a (re-analysing a dump, not paging)")
    else:
        print(f"coverage check pages*size    : {pages * args.limit} >= {returned_total} "
              f"-> {'OK' if pages * args.limit >= returned_total else 'SHORT -- TRUNCATED SWEEP'}")
        print( "terminator                   : page.has_more=false (a short page is "
               "never read as the end of the board; see fetch_all)")

    print("\nPOSITIVE CONTROL (rows that MUST be present):")
    missing = []
    for pcid in POSITIVE_CONTROLS:
        r = rows.get(pcid)
        if r is None:
            missing.append(pcid)
            print(f"  MISSING  {pcid}   <-- the sweep cannot see a row it was told about")
        else:
            cl = r.get("claim") or {}
            print(f"  present  {pcid}  lifecycle={r.get('lifecycle_status')} "
                  f"claim.worker={cl.get('worker')!r} epoch={cl.get('epoch')} "
                  f"expired_at={get(cl,'expired_at')!r} closed_at={get(cl,'closed_at')!r}")
    if missing:
        # A CONTROL THAT ONLY PRINTS IS A DECORATION (wave 47). This line said
        # "every zero below is UNTRUSTWORTHY" and then the process exited 0, so
        # a caller reading the exit code got a pass over a sweep that could not
        # see rows it was told about. It now leaves via the same refusal the
        # empty denominator does.
        print("  ** control failed: every zero below is UNTRUSTWORTHY **")

    # ---- lifecycle + claim presence ---------------------------------------
    life = collections.Counter(r.get("lifecycle_status") for r in rows.values())
    with_claim = [r for r in rows.values() if isinstance(r.get("claim"), dict)]
    print(f"\nLIFECYCLE over {N} rows:")
    for k, v in life.most_common():
        print(f"  {str(k):<14} {pct(v, N)}")
    print(f"\nrows carrying a claim map    : {pct(len(with_claim), N)}")

    # ---- SHAPE 0: open claim (no closed_at) with expired_at null ----------
    shape0 = [r for r in with_claim
              if get(r["claim"], "closed_at") is None and get(r["claim"], "expired_at") is None]
    print("\n" + "-" * 78)
    print("SHAPE 0 (crit 0) -- claim present, closed_at NULL, expired_at NULL")
    print(f"  count: {pct(len(shape0), N)}   [denominator = all {N} rows, {pages} pages]")
    fam = collections.Counter(r["doc_id"].split("-")[0] for r in shape0)
    famall = collections.Counter(r["doc_id"].split("-")[0] for r in rows.values())
    print("  per-family (id prefix), shape0 / all rows in that family:")
    for f, c in fam.most_common():
        print(f"    {f:<16} {c:>5} / {famall[f]:<5}")
    s0worker = collections.Counter(
        "worker SET" if get(r["claim"], "worker") else "worker NULL" for r in shape0)
    for k, v in s0worker.most_common():
        print(f"  {k:<12} {pct(v, len(shape0))}")
    s0life = collections.Counter(r.get("lifecycle_status") for r in shape0)
    print("  by lifecycle: " + ", ".join(f"{k}={v}" for k, v in s0life.most_common()))

    # ---- SHAPE B (crit 4): the LAPSED population, UNFINISHED vs UNPAID ----
    # LAPSED == the sweeper actually reaped this claim: expired_at is set.
    # Restricted to rows that are still live (not closed/cancelled), because a
    # reap on an already-finished row is history, not a stranded lease.
    lapsed = [r for r in with_claim
              if get(r["claim"], "expired_at") is not None
              and (r.get("lifecycle_status") or "") not in CLOSED_LIFECYCLES]
    # UNFINISHED vs UNPAID, defined from the row's OWN fields:
    #   UNPAID     = criteria_progress.total > 0 and met == total -- the work is
    #                demonstrably done, only the close never happened.
    #   UNFINISHED = criteria_progress.total > 0 and met < total.
    #   UNKNOWN    = the row carries no acceptance criteria to judge by.
    def bucket(r):
        cp = r.get("criteria_progress") or {}
        met, tot = cp.get("met") or 0, cp.get("total") or 0
        if tot == 0:
            return "UNKNOWN (no criteria)"
        return "UNPAID (all criteria met)" if met >= tot else "UNFINISHED (criteria outstanding)"
    lb = collections.Counter(bucket(r) for r in lapsed)
    print("\n" + "-" * 78)
    print("SHAPE B (crit 4) -- LAPSED claims on still-live rows")
    print("  LAPSED := claim.expired_at set (TtlSweeper.apply_reap/1 stamped it)")
    print("            AND lifecycle_status not in " + str(sorted(CLOSED_LIFECYCLES)))
    print(f"  count: {pct(len(lapsed), N)}   [denominator = all {N} rows, {pages} pages]")
    for k in ("UNFINISHED (criteria outstanding)", "UNPAID (all criteria met)", "UNKNOWN (no criteria)"):
        print(f"    {k:<34} {pct(lb.get(k, 0), len(lapsed))}   [denominator = the {len(lapsed)} lapsed]")
    if lapsed:
        oldest = sorted(lapsed, key=lambda r: get(r["claim"], "expired_at") or "")[:5]
        print("  oldest 5 by expired_at:")
        for r in oldest:
            print(f"    {get(r['claim'],'expired_at')}  {r['doc_id']}  "
                  f"({r.get('lifecycle_status')}, {bucket(r)})")

    # ---- SHAPE C (crit 5): four buckets over OPEN rows carrying a claim ----
    open_with_claim = [r for r in with_claim
                       if (r.get("lifecycle_status") or "") not in CLOSED_LIFECYCLES]
    b_exp = [r for r in open_with_claim if get(r["claim"], "expired_at") is not None]
    b_rel = [r for r in open_with_claim if get(r["claim"], "released_at") is not None]
    b_both = [r for r in open_with_claim
              if get(r["claim"], "expired_at") is not None and get(r["claim"], "released_at") is not None]
    b_neither = [r for r in open_with_claim
                 if get(r["claim"], "expired_at") is None and get(r["claim"], "released_at") is None]
    b_third = [r for r in b_neither
               if get(r["claim"], "worker") is not None and get(r["claim"], "closed_at") is not None]
    D = len(open_with_claim)
    print("\n" + "-" * 78)
    print("SHAPE C (crit 5) -- four buckets, ONE denominator")
    print(f"  OPEN rows carrying a claim   : {pct(D, N)}   [{pages} pages, {N} rows swept]")
    print(f"    A. expired_at set          : {pct(len(b_exp), D)}")
    print(f"    B. released_at set         : {pct(len(b_rel), D)}")
    print(f"       (overlap A&B)           : {pct(len(b_both), D)}")
    print(f"    C. NEITHER                 : {pct(len(b_neither), D)}")
    print(f"    D. of C: worker SET AND closed_at SET (the 'third shape')")
    print(f"                               : {pct(len(b_third), D)}   [also {pct(len(b_third), len(b_neither))} of bucket C]")
    print(f"  arithmetic check: A + B - overlap + C = "
          f"{len(b_exp)} + {len(b_rel)} - {len(b_both)} + {len(b_neither)} = "
          f"{len(b_exp)+len(b_rel)-len(b_both)+len(b_neither)} vs D={D} "
          f"-> {'OK' if len(b_exp)+len(b_rel)-len(b_both)+len(b_neither) == D else 'MISMATCH'}")
    for r in sorted(b_third, key=lambda r: r["doc_id"])[:20]:
        cl = r["claim"]
        print(f"      {r['doc_id']}  worker={cl.get('worker')!r} closed_at={cl.get('closed_at')}")

    # ---- SHAPE C: THE DENOMINATOR, NAMED, AND THE REFUSAL BESIDE IT -------
    # (wave 47, pds-bl-w47-stale-claim-third-shape-rescoped criterion 3.)
    # A printer with no verdict cannot report a false green -- but it also
    # cannot report a true one, and a reader takes "D. ... : 0" for a clean
    # board. So the population is STATED, not implied: the denominator, the
    # lifecycle values it actually admits (DERIVED from the rows swept, never
    # a list this file remembers), and the specimen count. Two things it
    # refuses to let a reader assume:
    #   - an EMPTY denominator is not a pass, it is a sweep that measured
    #     nothing -- exit 1;
    #   - a ZERO over a non-empty denominator is stated as UNEXERCISED unless
    #     a specimen was actually seen. `scripts/pds-ledger-census.sh` shipped
    #     for weeks reading `lifecycle_status == "open"` literally while ALL 19
    #     live specimens were `blocked`: a full denominator and a narrow key.
    admitted = sorted({(r.get("lifecycle_status") or "<unset>") for r in open_with_claim})
    print("\n  DENOMINATOR STATED: %d row(s) carry a claim and a non-terminal lifecycle"
          % D)
    print("    lifecycles ADMITTED (derived from the rows swept): %s"
          % (", ".join(admitted) if admitted else "(none -- the denominator is EMPTY)"))
    print("    lifecycles EXCLUDED as terminal: %s" % ", ".join(sorted(CLOSED_LIFECYCLES)))
    print("    SPECIMENS FOUND (bucket D, the third shape): %d" % len(b_third))
    if missing:
        print("    REFUSED: %d named positive control row(s) the sweep was told about were NOT"
              " seen (%s). Nothing above is a measurement of the board."
              % (len(missing), ", ".join(missing)))
    if D == 0:
        print("    REFUSED: the denominator is EMPTY. Zero specimens over zero rows is not a"
              " clean board, it is a sweep that measured nothing.")
        shape_c_refusal = ("shape C measured an EMPTY denominator -- no swept row carries a claim "
                           "under a non-terminal lifecycle")
    elif missing:
        shape_c_refusal = ("the sweep could not see %d named positive control row(s) (%s), so every "
                           "zero it printed is UNTRUSTWORTHY" % (len(missing), ", ".join(missing)))
    elif not b_third:
        print("    This 0 is UNEXERCISED: no row of this shape was seen anywhere in the sweep,"
              " so it proves the sweep found none -- not that the key can find one.")
        shape_c_refusal = None
    else:
        shape_c_refusal = None

    # ---- SHAPE D (crit 6): lifecycle=open WITH a live claim.worker --------
    ghost = [r for r in with_claim
             if r.get("lifecycle_status") == "open" and get(r["claim"], "worker")]
    print("\n" + "-" * 78)
    print("SHAPE D (crit 6) -- lifecycle_status == 'open' AND claim.worker non-null")
    print("  (the shape sweep2.py cleared to zero on 2026-09-05; TtlSweeper only")
    print("   reaps lifecycle_status == 'in_progress', so this shape is invisible")
    print("   to the sweeper by construction)")
    print(f"  count: {pct(len(ghost), N)}   [denominator = all {N} rows, {pages} pages]")
    for r in sorted(ghost, key=lambda r: r["doc_id"])[:40]:
        cl = r["claim"]
        print(f"    {r['doc_id']}  worker={cl.get('worker')!r} epoch={cl.get('epoch')} ts={cl.get('ts_iso')}")
    print("=" * 78)

    # THE ONLY NON-ZERO EXIT. Finding specimens is a FINDING and stays exit 0 --
    # this file is a census, not a merge gate, and callers read its stdout. A
    # denominator of zero is different in kind: nothing was measured, so nothing
    # printed above may be read as a result.
    if shape_c_refusal:
        print("REFUSAL: %s" % shape_c_refusal, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
