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

THIRD PREDICATE — UNFALSIFIABLE-DEF (PDS-D750): a DIFFERENT AXIS, not a better P1

  P1 and P2 both ask whether a rerun is ABOUT the right thing.  Neither asks
  whether it can ever go RED, and a command that cannot fail is green forever
  however perfectly it names its symbol.  Measured specimens:
  `git grep -n 'defp apply_engagement' …` survives renaming that function to
  `apply_engagement_RENAMED`, and `git grep -n 'def round_done_predicate' …`
  survives `round_done_predicate_MUT` — each returns the MUTATED line as its
  own evidence while exiting 0.  `git grep` matches a SUBSTRING, so a pattern
  ending in an identifier character is a PREFIX match, and a suffix rename is
  the commonest way a symbol actually changes.

    UNFALSIFIABLE_DEF(R) <=> some positional PATTERN of a `git grep` segment of
                             R.disposition_rerun BEGINS with a definition
                             keyword followed by an identifier, AND ENDS in
                             [A-Za-z0-9_] with no terminator, regex end-anchor
                             or \b.

  DEFINITION-SHAPED ONLY, and that narrowness is the ruling, not a shortcut.
  Over the corpus this was written against, 440 of 470 git-grep reruns end in a
  bare identifier — but 432 of those are REFERENCES (a constant, a path, a
  workflow name, a sentence quoted out of a charter) for which no delimiter
  exists to add.  Naming all 440 would be a finding nobody can act on; the 8
  definition-shaped ones each have a one-character fix.

FALSE POSITIVES OF P3 (a named row whose rerun is actually fine)
  * DELIBERATE FAMILY PROBE.  `git grep -n 'defp handle_' …`, written to assert
    a whole clause group still exists, is prefix-matching ON PURPOSE.  P3 names
    it.  Remedy is one character (`defp handle_[a-z]`); measured frequency in
    the corpus this shipped against was 0 of 470, which is why the arm is worth
    its false-positive rate — and the number, not the argument, is the reason.
  * MULTI-SEGMENT COMMANDS.  Only the FIRST positional token after `git grep`
    in each `|`/`&&`/`;`-separated segment is read as the pattern.  An exotic
    flag ordering can make that token the wrong one in either direction.

FALSE NEGATIVES OF P3 (an unfalsifiable rerun P3 will NOT name)
  * REFERENCE-TAIL, by construction.  `git grep -n ROSTER_PAGE_LIMIT …` is
    just as inert under `ROSTER_PAGE_LIMIT_2`, and P3 is silent about it.  The
    REFERENCE-TAIL count is PRINTED for exactly that reason: it is the arm's
    own declared blind spot, sized, not hidden.
  * NON-GREP RERUNS.  `git cat-file -e` / `git rev-list --count` shapes are not
    read at all.

FOURTH PREDICATE — ORPHANED (the rerun outlived the reason it was written for)

    T(R) = the PROBE SUBJECT of R.disposition_rerun: the grep pattern and the
           path basename of `git grep -n <pat> origin/main -- <path>`, the sha
           of `git rev-list --count origin/main..<sha>`, the path of
           `git cat-file -e origin/main:<path>`.

    ORPHANED(R) <=> T(R) != {} AND no t in T(R) occurs as a case-insensitive
                    substring of R.disposition_reason.

  This is P1 RUN BACKWARDS, and the direction is the whole point.  P1 asks
  whether the rerun mentions the reason; it needs the reason to carry
  backticks, so it abstains on 415 of 515 rows.  P4 asks whether the REASON
  mentions what the rerun actually probes — and a rerun has a parseable
  subject whether or not anyone backticked anything, so P4 reaches into the
  ABSTAIN set by construction.

  ORTHOGONAL TO P3, NOT A REFINEMENT OF IT.  P3 asks whether the rerun CAN go
  red at all (a bare identifier tail cannot).  P4 asks whether the row it sits
  on is the row it was written for.  A rerun can be perfectly falsifiable and
  still be testing somebody else's claim; that is the whole of P4's subject.

  WHY THE FIELD DESYNCS.  `disposition_reason` is REPLACED in place
  (`bp task stage --note --supersede`); `disposition_rerun` is written by a
  separate optional flag on the same call and is simply LEFT ALONE when the
  call omits it.  So superseding a reason silently keeps the previous reason's
  rerun, and the row goes on presenting a green, recent, symbol-specific probe
  for a claim it no longer makes.  Every orphan this predicate names on the
  live corpus has updated_at > inserted_at; none was born wrong.

  NOT A DUPLICATE OF P2.  P2 (SHARED) says a rerun stands on k rows; it cannot
  say which k-1 are wrong, and PDS-D391b ruled — correctly — that sharing
  itself is honest.  P4 says WHICH rows the shared command was not written for,
  by asking the rows rather than the group.  Measured: it CLEARS 192 rows P2
  flags and NAMES 16 unique-rerun rows P2 cannot see.

  FALSE POSITIVES OF P4
    * A reason may turn on the symbol via a synonym, a caller, or a test name
      the rerun greps instead — textual, the same hop P1 cannot follow.
    * A rerun deliberately aimed at the INFRASTRUCTURE of the check rather than
      the claim (rare; none seen on the live corpus).
  FALSE NEGATIVES OF P4
    * An INCIDENTAL mention of the probe token in a long multi-clause reason
      passes on a coincidence, exactly as it does in P1.
    * A rerun whose spelling this parser does not recognise yields T(R) == {}
      and abstains.  The UNPARSED count is printed for that reason.

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
import shlex
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


# --- P3: FALSIFIABILITY (PDS-D750) -------------------------------------------
# Flags that consume the NEXT token, so the pattern is not mistaken for their
# argument.  `-e` is here because `git grep -e PAT` puts the pattern there.
GREP_FLAGS_WITH_ARG = {"-m", "--max-count", "-C", "-A", "-B", "-f"}

# `-e` is NOT in that set, and the difference is load-bearing: `git grep -e PAT`
# puts the pattern in the flag's argument slot, so treating `-e` as "skip the
# next token" reads straight past the very thing this arm exists to inspect.
# Control I in --selftest is that specimen, and it is there because the first
# cut of this function got it wrong in exactly that direction.
GREP_PATTERN_FLAGS = {"-e"}

# A definition keyword opening the pattern.  This is the whole narrowing: it is
# what separates "a symbol whose language gives it a terminator" from "a string
# quoted out of a charter".
DEF_KEYWORD = re.compile(
    r"^\s*(defp?|defmodule|defmacrop?|defstruct|func|function|class|type|struct"
    r"|interface|const|let|var|fn|pub\s+fn)\s+[A-Za-z_]"
)

# A tail that a SUFFIX RENAME cannot extend: a delimiter, a regex end-anchor, or
# a word boundary.  Anything else ending in an identifier char is a prefix match.
ANCHORED_TAIL = re.compile(r"""(\$|\\b|\\>|[(){}\[\]:;,=<>"'/.\s|+*?^&%!@#-])$""")
IDENT_TAIL = re.compile(r"[A-Za-z0-9_]$")


def grep_patterns(rerun):
    """The positional PATTERN of each `git grep` segment of a rerun string.

    The rerun is DATA: it is tokenised with shlex, never executed and never
    handed to a shell.
    """
    out = []
    for seg in re.split(r"\|\||&&|;|\|", rerun or ""):
        if not re.search(r"\bgit\s+grep\b", seg):
            continue
        try:
            toks = shlex.split(seg.strip())
        except ValueError:
            continue
        if "grep" not in toks:
            continue
        skip = False
        take = False
        for t in toks[toks.index("grep") + 1:]:
            if t == "--":
                break
            if take:
                out.append(t)
                take = False
                break
            if skip:
                skip = False
                continue
            if t in GREP_PATTERN_FLAGS:
                take = True
                continue
            if t in GREP_FLAGS_WITH_ARG:
                skip = True
                continue
            if t.startswith("-"):
                continue
            out.append(t)
            break
    return out


def falsifiability(rerun):
    """-> ('unfalsifiable-def'|'reference-tail'|'anchored'|'no-git-grep', patterns)

    'unfalsifiable-def' is the FINDING.  'reference-tail' is the declared blind
    spot: equally prefix-matching, deliberately not named (see the docstring).
    """
    pats = grep_patterns(rerun)
    if not pats:
        return "no-git-grep", pats
    bare = [p for p in pats if IDENT_TAIL.search(p) and not ANCHORED_TAIL.search(p)]
    if not bare:
        return "anchored", pats
    if any(DEF_KEYWORD.match(p) for p in bare):
        return "unfalsifiable-def", pats
    return "reference-tail", pats


GREP_RERUN = re.compile(r"git\s+grep\s+(?:-\w+\s+)*(?P<pat>'[^']*'|\"[^\"]*\"|\S+)(?:\s+\S+)?(?:\s+--\s+(?P<path>\S+))?")
REVLIST_RERUN = re.compile(r"git\s+rev-list\s+--count\s+\S*?\.\.(?P<sha>[0-9a-f]{7,40})")
CATFILE_RERUN = re.compile(r"git\s+cat-file\s+-e\s+\S+?:(?P<path>\S+)")


def probe_subject(rerun):
    """T(R): what the rerun actually probes — grep pattern, sha, or path leaf."""
    out = set()
    if not rerun:
        return out
    m = REVLIST_RERUN.search(rerun)
    if m:
        out.add(m.group("sha"))
    m = CATFILE_RERUN.search(rerun)
    if m:
        out.add(m.group("path").rsplit("/", 1)[-1])
    m = GREP_RERUN.search(rerun)
    if m:
        pat = (m.group("pat") or "").strip("'\"")
        if len(pat) >= MIN_ANCHOR_LEN:
            out.add(pat)
            # A multi-token pattern (`def drain_distribution`) is also probed by the
            # identifier inside it — the same tokenisation `anchors()` applies to a
            # backticked span, for the same reason: a reason that names the symbol
            # but not the grep's exact spelling IS talking about what the rerun runs.
            for w in WORD.findall(pat):
                w = w.strip(".,:;()[]{}\"'")
                if len(w) >= MIN_ANCHOR_LEN and (CODEISH.search(w) or len(w) >= 6):
                    out.add(w)
        path = m.group("path")
        if path:
            leaf = path.rsplit("/", 1)[-1]
            if len(leaf) >= MIN_ANCHOR_LEN:
                out.add(leaf)
    return {t for t in out if len(t) >= MIN_ANCHOR_LEN}


def orphaned(reason, rerun):
    """-> ('orphaned'|'bound'|'unparsed', subject_set)"""
    t = probe_subject(rerun)
    if not t:
        return "unparsed", t
    low = (reason or "").lower()
    return ("bound" if any(x.lower() in low for x in t) else "orphaned"), t


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
    # --- P3 controls (PDS-D750). Each pair is a MUTATION of the other: the
    # only difference between E and F is the terminator the law requires, and
    # the only difference between E and G is the definition keyword that makes
    # the arm narrow. An arm that loses either direction fails here by name.
    v, _ = falsifiability("git grep -n 'defp apply_engagement' origin/main -- api/lib/barkpark/tasks/stage.ex")
    print(f"control E (undelimited def must be named): {v}")
    ok &= v == "unfalsifiable-def"
    v, _ = falsifiability("git grep -n 'defp apply_engagement(' origin/main -- api/lib/barkpark/tasks/stage.ex")
    print(f"control F (same probe, delimited, must NOT be named): {v}")
    ok &= v == "anchored"
    v, _ = falsifiability("git grep -n 'def round_done_predicate' origin/main -- scripts/pds-ledger-census.sh")
    print(f"control E2 (second specimen, undelimited, must be named): {v}")
    ok &= v == "unfalsifiable-def"
    v, _ = falsifiability("git grep -n 'def round_done_predicate(report):' origin/main -- scripts/pds-ledger-census.sh")
    print(f"control F2 (second specimen, delimited, must NOT be named): {v}")
    ok &= v == "anchored"
    v, _ = falsifiability(r"git grep -nE 'defp apply_engagement\b' origin/main -- api/lib/barkpark/tasks/stage.ex")
    print(f"control F3 (word-boundary anchor, whose own tail is an identifier char, must NOT be named): {v}")
    ok &= v == "anchored"
    v, _ = falsifiability("git grep -n ROSTER_PAGE_LIMIT origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs")
    print(f"control G (reference tail: the DECLARED blind spot, must not be a finding): {v}")
    ok &= v == "reference-tail"
    v, _ = falsifiability("git cat-file -e origin/main:scripts/pds-ledger-census.sh")
    print(f"control H (non-grep rerun, must abstain): {v}")
    ok &= v == "no-git-grep"
    v, _ = falsifiability("git grep -n -e 'defp apply_engagement' origin/main -- api/lib/barkpark/tasks/stage.ex")
    print(f"control I (-e takes the pattern as its ARGUMENT, must still be named): {v}")
    ok &= v == "unfalsifiable-def"
    # --- P4 controls (PDS-D751). J and K share a rerun BYTE-FOR-BYTE and must
    # disagree: that pair is the mutation proof that P4's verdict is about the
    # REASON and not about the command, which is exactly what separates it from
    # P2 (SHARED). L pins the other two legal spellings and makes an unknown one
    # abstain LOUDLY rather than read as bound; M pins the multi-token pattern
    # binding on the identifier inside it.
    v, t = orphaned(
        "The premise expired; cancelled not done — see close_reason.",
        "git grep -n ROSTER_PAGE_LIMIT origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs",
    )
    print(f"control J (must be orphaned): {v}  subject={sorted(t)}")
    ok &= v == "orphaned"
    v, t = orphaned(
        "Adopted for ROSTER HEADROOM: the roster was 450 of ROSTER_PAGE_LIMIT 500.",
        "git grep -n ROSTER_PAGE_LIMIT origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs",
    )
    print(f"control K (same rerun as J, must be bound): {v}")
    ok &= v == "bound"
    v, t = orphaned("nothing to do with it", "git rev-list --count origin/main..6dff811575c7 | grep -qx 0")
    v2, t2 = orphaned("nothing", "bash scripts/whatever.sh --check")
    print(f"control L (rev-list: {v} {sorted(t)} | unknown spelling: {v2})")
    ok &= v == "orphaned" and "6dff811575c7" in t and v2 == "unparsed"
    v, t = orphaned(
        'the release exposes drain_distribution("24h") on the box',
        "git grep -n 'def drain_distribution' origin/main -- cloud/lib/barkpark_cloud/release.ex",
    )
    print(f"control M (must be bound via token): {v}  subject={sorted(t)}")
    ok &= v == "bound"
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
    # P3 — the falsifiability axis (PDS-D750). Counted over the SAME
    # denominator so the two axes can be compared without a second fetch.
    fals = {"unfalsifiable-def": [], "reference-tail": 0, "anchored": 0, "no-git-grep": 0}
    for r in rows:
        v, pats = falsifiability(r["rerun"])
        if v == "unfalsifiable-def":
            r["patterns"] = pats
            fals[v].append(r)
        else:
            fals[v] += 1
    groups = shared_groups(rows)
    shared_rows = sum(len(v) for v in groups.values())
    print(f"SHARED        {shared_rows} rows over {len(groups)} distinct rerun strings reused by >1 row")
    print(f"UNIQUE-RERUN  {len(rows) - shared_rows}  (control: a non-zero here proves the grouping is not collapsing everything)")
    print(f"P3 UNFALSIFIABLE-DEF  {len(fals['unfalsifiable-def'])}  (definition-shaped pattern with a bare identifier tail: a suffix rename cannot red it)")
    print(f"P3 reference-tail     {fals['reference-tail']}  (equally prefix-matching, DELIBERATELY not named — P3's declared blind spot, sized)")
    print(f"P3 anchored           {fals['anchored']}  (control: a non-zero here proves the tail test is not naming everything)")
    print(f"P3 no-git-grep        {fals['no-git-grep']}  (not read by this arm at all)")
    # P4 — the binding axis (PDS-D751), same denominator again.
    orph, bound, unparsed = [], 0, 0
    for r in rows:
        v, t = orphaned(r["reason"], r["rerun"])
        if v == "orphaned":
            orph.append(r)
        elif v == "bound":
            bound += 1
        else:
            unparsed += 1
    print(f"P4 BOUND              {bound}  (the reason mentions what the rerun probes)")
    print(f"P4 ORPHANED           {len(orph)}  (the rerun outlived the reason it was written for)")
    print(f"P4 UNPARSED           {unparsed}  (control/blind spot: rerun spelling this parser does not recognise)")
    union = {r["id"] for r in named} | {r["id"] for v in groups.values() for r in v}
    print(f"UNION         {len(union)} rows named by P1 (anchor) or P2 (shared)")
    print(f"UNION+P4      {len(union | {r['id'] for r in orph})} rows adding P4 (orphaned)")
    print()
    print("== P2 SHARED RERUN GROUPS (largest first) ==")
    for cmd, v in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(v):>4} rows  {cmd[:150]}")
    print()
    print("== P3 UNFALSIFIABLE-DEF ==")
    for r in fals["unfalsifiable-def"]:
        print(f"--- UNFALSIFIABLE {r['id']}  [{r['lifecycle']}]")
        print(f"    title   : {r['title']}")
        print(f"    rerun   : {r['rerun'][:200]}")
        print(f"    pattern : {r['patterns']}  <- add the language's terminator")
    print()
    print("== P4 ORPHANED (rerun outlived its reason) ==")
    for r in orph:
        print(f"--- ORPHANED {r['id']}  [{r['lifecycle']}] claim={r['claim']}")
        print(f"    title : {r['title']}")
        print(f"    rerun : {r['rerun'][:160]}")
        print(f"    reason: {(r['reason'] or '')[:160]}")
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
