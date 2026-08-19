<!-- doc-tier: cold | canonical-for: cch-w77-v4-seal-orphan-census | budget: 900tok -->
# cch-w77 V4 — live seal verdict + 422-orphan class census (re-derivation)

Verifier V4-seal-predicate-live-orphan-census. Repo HEAD == origin/main tip
`8dadc9b5` (worktree a6535504, identical content). All facts re-derivable below.

## 1. Run the seal LIVE (origin/main tip)
    cd /Volumes/SATECHI/github/barkpark
    node cloud/priv/static/__preview__/seal-predicate.mjs \
      --epic cloud-console-hardening-epic --successor cch-instruments-epic 2>&1 | grep VERDICT-TOKEN
Expect:
    VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=422 considering=1 \
      successor=cch-instruments-epic epic=cloud-console-hardening-epic mode=live stubbed=0 \
      waived=0 roster=928 repo=... head=a653550420
Clause a FAILS on 422 unforwarded residue; b PASS (6 defects D1-D6 rung-1/2); c PASS (3 human gates).

## 2. Enumerate + classify the residue (the run prints only 8 orphans)
Token from ~/.config/barkpark/config.json. Paginate parent_id filter, order `_createdAt asc`:
    curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
      --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
      --data-urlencode 'limit=200' --data-urlencode 'offset=<0,200,400,600,800>' \
      --data-urlencode 'order=_createdAt asc' --data-urlencode 'count=true' \
      -H "Authorization: Bearer <bp_admin token>"
Roster = 928 children {done:429, open:423, in_progress:1, cancelled:74, considering:1}.
Residue (open+in_progress+considering) = 425.  Orphans (residue - 3 gates) = 422.

## 3. CLASS CENSUS of residue (slug-prefix tally)
    397  cch-*   (THIS epic's own prior-wave slice rows, waves 12-71)
     12  gr-*    (inherited GUI-remake FEATURE/OPS backlog)
     13  task-*  (bare-id, untitled)  +  1 disclosed considering (cloud-console-operator-audit-log)
cch-* suffix split: 313 -bl, ~42 -sN, 5 -fu. Functional (heuristic) within cch-*:
~77 instrument/census/gate/charter, ~41 honesty/refusal-copy, ~23 billing/feature, ~256 other console defects.

## 4. Progress ratio of residue (batch-close-trap check)
    406/425 are 0/N (genuinely UNBUILT, zero criteria met)
     19/425 partial (incl. the survivor cch-w74 @ 3/4, in_progress)
      0/425 N/N stale-open  => NO batch-close-by-ratio trap remains in current residue.

## 5. Successor anti-null guards R2-R6 — PASS
cch-instruments-epic: lifecycle_status=open, published task, no parent_id (top-level),
!= the epic under judgement. R2 named / R3 resolves / R4 not-self / R5 not-corpse
(open in SUCCESSOR_LIVE_STATUSES) / R6 not-inside-epic — all pass; that is why the run
reached VERDICT with a=FAIL purely on the 422 unforwarded orphans, not UNRESOLVABLE-SUCCESSOR.

## FINDING FOR DECIDE
The digest's premise — residue is "overwhelmingly inherited gr-* GUI-remake feature/ops
backlog" — is REFUTED. Only 12 orphans are gr-*. 397 are cch-* — this epic's OWN unbuilt
wave slices. Forwarding them into an INSTRUMENTS successor is a bucket-mismatch for the
~256 non-instrument console-defect rows (D93/D94). Honest close is a RULING (honesty arc
D1-D6 complete + instrument-enforced) NOT a forced a=PASS seal.
