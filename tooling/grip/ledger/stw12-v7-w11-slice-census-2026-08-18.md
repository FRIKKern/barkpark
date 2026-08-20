# Re-derivation: stw11-bl-w11-slices-never-filed is a STALE-OPEN close (8/8 W11 slices exist)

Verifier assignment v7-w11-slice-census. Verdict: the "never filed" premise is REFUTED —
all 8 W11 slices from search-template-wave-2026-07-28 exist as PUBLISHED children of
search-template-epic-goal. The re-file build collapses to a close-by-evidence; a blind
re-file would DUPLICATE rows.

## Re-derive the 8-of-8 enumeration

    bp task get search-template-epic-goal -o json \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted(c['doc_id'] for c in d['children'] if c['doc_id'].startswith('stw11-')))"

Expect exactly 8:
  stw11-a11y-invariants          done  met=7/7
  stw11-astro-phone-waterfall    open  met=0/7   (claimable, unclaimed)
  stw11-bl-w11-slices-never-filed open met=0/2   (this row — the close candidate)
  stw11-claim-ledger             open  met=0/9
  stw11-ledger-honesty           open  met=0/9
  stw11-provenance-line          open  met=0/7
  stw11-readme-command-gate      open  met=0/7   (STALE-OPEN — #6941 merged)
  stw11-vendor-freshness-gate    open  met=0/7   (STALE-OPEN — #6939 merged)

Wave paper corroboration ("8 slices cut"):

    bp paper view search-template-wave-2026-07-28 | grep "8 slices cut"
    # -> "Status: BUILDING — Decide is done, 8 slices cut"

## Criterion satisfaction for stw11-bl-w11-slices-never-filed (met=0/2 → both satisfiable)

Crit 1 "All 8 W11 slice tasks ... exist as published children ... verified by a bp task get
read-back": SATISFIED — enumeration above; each is status:published.

Crit 2 "stw11-astro-phone-waterfall specifically is claimable, carrying the astro island
mount-gate brief": SATISFIED — read-back shows status:published, lifecycle:open, claim:null,
7 acceptance criteria; crit 1 of that brief = "Astro graph portal gated on a media query
... in a file OUTSIDE src/finder/" (the island mount-gate).

    bp task get stw11-astro-phone-waterfall -o json \
      | python3 -c "import json,sys; d=json.load(sys.stdin)['doc']; print(d['status'], d['lifecycle_status'], d.get('claim'))"
    # -> published open None

## a11y-invariants re-stamp target (already done, met=7/7)

    git merge-base --is-ancestor 32f2bea48 origin/main && echo a11y-squash-ANCESTOR
    # -> a11y-squash-ANCESTOR

So stw11-a11y-invariants (done) is re-stampable to squash SHA 32f2bea48.

## Close recipe for Decide (one phase later)

Re-claim lapsed claim on stw11-bl-w11-slices-never-filed (read CURRENT holder+epoch
immediately before close), stamp both criteria met with evidence = the 8-of-8 enumeration
command + astro read-back, close done. Do NOT re-file any stw11-* row.
