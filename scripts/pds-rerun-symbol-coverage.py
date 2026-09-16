#!/usr/bin/env python3
"""pds-rerun-symbol-coverage — name every ledger row whose disposition_rerun
command does not mention any symbol its disposition_reason turns on.

WHY THIS EXISTS
  A rerun that passes while exercising a clause ADJACENT to its reason is, at
  the census level, indistinguishable from a working one: it is green, it is
  recent, it looks maintained.  pds-dedup-unavailable-503-is-still-a-409 was
  the specimen — its rerun greened on an unrelated `{:halted}` clause while the
  reason's claim (409 vs 503) had already been refuted on main.

  This is a PREDICATE, not a list.  A list of the six slugs found today goes
  stale the moment a seventh row is written.

THE PREDICATE
  For a row R with a non-null disposition_rerun:

    A(R) = the ANCHOR SET of R.disposition_reason
         = every backticked span of the reason, trimmed, plus every word token
           inside such a span, keeping only members that are >= MIN_ANCHOR_LEN
           characters AND look like code (contain one of _ . / : - or are a
           >=6-char identifier).

    NAMED(R)  <=>  A(R) != {} AND no a in A(R) occurs as a case-insensitive
                   substring of R.disposition_rerun.

  NAMED rows are the finding.  A(R) == {} is ABSTAIN, not a pass: a prose-only
  reason carries no machine-checkable anchor at all and this predicate is blind
  to it by construction (see FALSE NEGATIVES).

FALSE POSITIVES (a NAMED row that is actually fine)
  * INDIRECT REACH.  A reason may turn on a symbol the rerun reaches through a
    caller, a test name, or a file path rather than by literal mention —
    e.g. a reason about `disposition` vacuity whose rerun greps the test's
    title string instead.  The predicate is textual and cannot follow that hop.
  * MULTI-CLAUSE REASONS.  A long reason often carries a corrected-figure
    preamble whose backticks (`git archive origin/main | tar -x`, `wc -c`)
    outnumber the operative clause's.  Those inflate A(R) with anchors the
    rerun was never meant to mention.
  * RENAMED SYMBOL.  If the symbol was renamed on main and the rerun was
    retargeted at the new name while the reason still quotes the old one, the
    row is named although the rerun is the more current of the two.

FALSE NEGATIVES (a broken rerun this predicate will NOT name)
  * PROSE-ONLY REASONS.  A(R) == {} abstains.  Rows whose reason uses no
    backticks are invisible here however badly targeted their rerun is.
    The ABSTAIN count is printed for exactly this reason — treat it as the
    predicate's own blind spot, sized.
  * INCIDENTAL MENTION.  A rerun that names an anchor only in its `-- <path>`
    filter, or that greps a common word the reason happens to backtick, passes
    on a coincidence.  Mentioning a symbol is not testing it.
  * WRONG-CLAUSE-SAME-FILE.  The exact specimen shape, when the adjacent clause
    lives in the same symbol's file and the reason backticks that filename.
    Textual overlap cannot distinguish "tests the claim" from "tests its
    neighbour".  This predicate raises the floor; it is not the ceiling.

SECOND PREDICATE — SHARED (no anchors required, so it sees into the ABSTAIN set)

    SHARED(R) <=> R.disposition_rerun is byte-identical to the rerun of at
                  least one OTHER row.

  A single command cannot be the symbol-specific probe for k distinct reasons:
  at most one of the k rows can be the one it was written for, so k-1 of them
  carry a rerun that greens on something other than their own claim.  This
  predicate needs no backticks at all, which is exactly why it is here — it is
  the arm that reaches the rows P1 abstains on.  It under-reports (it cannot
  see a UNIQUELY wrong rerun) and it over-reports by one row per group (the row
  the command was genuinely written for is in the group too).

CONTROLS
  Run with --selftest: two synthetic rows, one that MUST be named and one that
  MUST NOT, plus an assertion that the live corpus produces a non-empty anchor
  set on a majority of rows.  A zero finding count from a broken extractor and
  a true zero are identical without this.

WHY .py AND NOT .sh — SAID OUT LOUD RATHER THAN LEFT TO BE DISCOVERED
  scripts/pds-door-census.sh enumerates `scripts/pds-*.{sh,exs}` only, so this
  file is OUTSIDE its population: it is neither disposed nor UNDISPOSED, it is
  invisible.  That is a deliberate, declared gap, not an oversight.  Landing it
  as a .sh pulls in the whole door contract at once — a DISPOSITION ledger row,
  a measured price, a derived *_test.sh, and the count assertion in
  api/test/barkpark/pds_door_census_test.exs, which reds main the moment the
  harness tally moves.  Paying half of that is how the census went red twice
  (see the pds-read-preflight-audit_test.sh and pds-live-hetzner-placement-group_test.sh
  rows).  The follow-up is: convert to .sh and pay the door in ONE change, or
  wire `--selftest` into .github/workflows/shell-harnesses.yml.  Until then this
  instrument is guarded by its own `--selftest` and by nothing else, and that
  sentence is the whole of its guarantee.

USAGE
  env -u BARKPARK_TOKEN bp task ls --all -o json > rows.json
  python3 scripts/pds-rerun-symbol-coverage.py rows.json
  python3 scripts/pds-rerun-symbol-coverage.py --selftest
"""
import json
import re
import sys

MIN_ANCHOR_LEN = 4
BACKTICK = re.compile(r"`([^`]+)`")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_./:!?-]*")
CODEISH = re.compile(r"[_./:-]")


def anchors(reason):
    """Anchor set of a reason: backticked spans and the code-ish words in them."""
    out = set()
    if not reason:
        return out
    for span in BACKTICK.findall(reason):
        span = span.strip()
        cands = [span] + WORD.findall(span)
        for c in cands:
            c = c.strip(".,:;()[]{}\"'")
            if len(c) < MIN_ANCHOR_LEN:
                continue
            if CODEISH.search(c) or len(c) >= 6:
                out.add(c)
    return out


def classify(reason, rerun):
    """-> ('named'|'covered'|'abstain', anchor_set, hits)"""
    a = anchors(reason)
    if not a:
        return "abstain", a, set()
    low = (rerun or "").lower()
    hits = {x for x in a if x.lower() in low}
    return ("covered" if hits else "named"), a, hits


def shared_groups(rows):
    """-> {rerun_string: [row, ...]} for every rerun used by more than one row."""
    by = {}
    for r in rows:
        by.setdefault(r["rerun"], []).append(r)
    return {k: v for k, v in by.items() if len(v) > 1}


def rows_from(path):
    with open(path) as fh:
        blob = json.load(fh)
    docs = blob["docs"] if isinstance(blob, dict) else blob
    for d in docs:
        c = d.get("content") or {}
        if c.get("disposition_rerun"):
            yield {
                "id": d.get("id"),
                "title": (d.get("title") or "")[:90],
                "claim": ((d.get("claim") or {}).get("worker")),
                "lifecycle": c.get("lifecycle_status"),
                "reason": c.get("disposition_reason") or "",
                "rerun": c.get("disposition_rerun") or "",
            }


def selftest():
    ok = True
    # CONTROL A — must be NAMED: reason turns on `parse_order`, rerun greps elsewhere.
    v, a, h = classify(
        "The silent path in `parse_order` drops the clause.",
        "git grep -n 'def build_filter' origin/main -- api/lib/x.ex",
    )
    print(f"control A (must be named): {v}  anchors={sorted(a)}")
    ok &= v == "named"
    # CONTROL B — must be COVERED: same reason, rerun that does mention it.
    v, a, h = classify(
        "The silent path in `parse_order` drops the clause.",
        "git grep -n 'defp parse_order(' origin/main -- api/lib/x.ex",
    )
    print(f"control B (must be covered): {v}  hits={sorted(h)}")
    ok &= v == "covered"
    # CONTROL C — abstain on a prose-only reason.
    v, a, h = classify("Closed by the lead at 8 of 10, no code cited.", "git grep -n foo origin/main")
    print(f"control C (must abstain): {v}")
    ok &= v == "abstain"
    # CONTROL D — SHARED groups only the duplicated string, never the unique one.
    rs = [
        {"rerun": "git grep -n A origin/main"},
        {"rerun": "git grep -n A origin/main"},
        {"rerun": "git grep -n B origin/main"},
    ]
    g = shared_groups(rs)
    print(f"control D (must group A only): {sorted(g)}  sizes={[len(v) for v in g.values()]}")
    ok &= list(g) == ["git grep -n A origin/main"] and len(next(iter(g.values()))) == 2
    print("SELFTEST", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    rows = list(rows_from(argv[1]))
    named, covered, abstain = [], 0, []
    for r in rows:
        v, a, h = classify(r["reason"], r["rerun"])
        r["anchors"] = sorted(a)
        if v == "named":
            named.append(r)
        elif v == "covered":
            covered += 1
        else:
            abstain.append(r)
    print(f"DENOMINATOR   {len(rows)} rows carry a disposition_rerun")
    print(f"COVERED       {covered}  (rerun mentions >=1 reason anchor)")
    print(f"NAMED         {len(named)}  (anchor set non-empty, rerun mentions none)")
    print(f"ABSTAIN       {len(abstain)}  (prose-only reason: no backticked anchor — the predicate's own blind spot)")
    groups = shared_groups(rows)
    shared_rows = sum(len(v) for v in groups.values())
    print(f"SHARED        {shared_rows} rows over {len(groups)} distinct rerun strings reused by >1 row")
    print(f"UNIQUE-RERUN  {len(rows) - shared_rows}  (control: a non-zero here proves the grouping is not collapsing everything)")
    union = {r["id"] for r in named} | {r["id"] for v in groups.values() for r in v}
    print(f"UNION         {len(union)} rows named by P1 (anchor) or P2 (shared)")
    print()
    print("== P2 SHARED RERUN GROUPS (largest first) ==")
    for cmd, v in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(v):>4} rows  {cmd[:150]}")
    print()
    print("== P1 NAMED ==")
    for r in named:
        print(f"--- NAMED {r['id']}  [{r['lifecycle']}] claim={r['claim']}")
        print(f"    title : {r['title']}")
        print(f"    rerun : {r['rerun'][:200]}")
        print(f"    anchors({len(r['anchors'])}): {', '.join(r['anchors'][:12])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
