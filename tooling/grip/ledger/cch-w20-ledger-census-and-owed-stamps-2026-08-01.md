# CCH wave 20 — ledger census, owed stamps, and the three circulating numbers

Verifier lane `ledger-census-and-owed-stamps`, read 2026-08-01T20:43Z. Every number below is
re-derivable by the command printed beside it. Nothing here is copied from a brief.

## 1. The seal predicate's OWN denominator

    node cloud/priv/static/__preview__/seal-predicate.mjs \
      --epic cloud-console-hardening-epic --successor cch-instruments-epic ; echo "EXIT=$?"

    roster: 248 children  {"open":85,"done":138,"cancelled":24,"considering":1}
    CLAUSE (a) forwarding — residue 86 (live 85, considering 1)
    VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=83 considering=1 …
    EXIT=1

**Law 0 arithmetic to state at first claim: 248 published children, 86 residue (85 open + 1
considering), 83 unnamed orphans.**

## 2. Why three numbers circulate — reconciled, not averaged

| source | number | what it is |
|---|---|---|
| seal predicate roster (`filter[parent_id]`, published only) | 248 = 85/138/24/1 | **the law's denominator** |
| `bp task get cloud-console-hardening-epic` | 251 = 86/138/26/1 | +3 `drafts.*` docs (Law 0 warns of exactly this) |
| charter D225 (wave-19 Decide) | 231 = 84/128/18/1 | an older read, correct then |
| wave-20 wish | "~70" | understated by 16 |

The three draft docs, enumerated:

    drafts.cch-bl-floor-is-blind-and-uncalled            cancelled  (draft-only id)
    drafts.cch-bl-required-checks-floor-blind-uncalled   cancelled  (draft-only id)
    drafts.cch-w19-s1-guard-loses-in-ci                  open       (twin of a PUBLISHED row)

Rerun: `bp task get cloud-console-hardening-epic -o json | jq '[.children[].doc_id|select(startswith("drafts."))]'`

## 3. Held rows: NONE

    curl -sG "$SERVER/v1/data/query/production/task" \
      --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' --data-urlencode 'limit=500'

159 of 248 rows carry a `claim` object. **Zero have a live hold**: no row has
`claim.expired_at` in the future, and no `open`/`in_progress` row has a non-null `claim.worker`.
The three wave-19 slices (`cch-w19-s1/s2/s4`) show `worker: null` with `previous_worker:
epic-builder-…` and a lapsed `expired_at` — released, freely claimable.

## 4. Owed merge-gated stamps — three, against three verified merge SHAs

    for n in 8944 8945 8946; do gh pr view $n --json number,state,mergeCommit,mergedAt; done
    git merge-base --is-ancestor <sha> origin/main   # all three: ON-MAIN

| row | unmet criterion | squash merge SHA | PR |
|---|---|---|---|
| `cch-w19-s1-guard-loses-in-ci` (7/9) | c9 | `4116674652c2d7040f0a00dde77852afba65af81` | #8944 |
| `cch-w19-s2-topbar-phone-band-620` (10/11) | c11 | `87e8726c47a2d60bd1cda29d0983c903deb1396c` | #8945 |
| `cch-w19-s4-wrap-parity-e14` (10/11) | c11 | `367e19810b34f7d7551204a862420d542c0a7c0e` | #8946 |

The other 37 unmet `MERGE-GATED` criteria on the epic belong to slices that have not been built.

## 5. `cch-w15-bl-overflow-guard-unwired` — stamp ALREADY DISCHARGED

`lifecycle_status=done`, `criteria_progress {"met":6,"total":6}`, `claim.closed_by =
wave19-reviewer` at 2026-08-01T19:55:25Z. c1 and c2 already quote runs 30707783158 /
30714372486 / 30714465001 and PR #8928 (CLOSED, mergeCommit null). **Stamping it again would be
manufactured progress.** s1's c9 therefore reduces to recording `4116674652…`.

## 6. s1's c3 is UNSTAMPABLE AS WRITTEN — amend by measurement

c3 demands the verbatim line `OVERFLOW GUARD FAIL — 2 finding(s) in:
GR109-attention-row-dead-rule`. The committed ledger
`tooling/grip/ledger/cch-w19-guard-mutation-proof-2026-08-01.md:60` records what actually ran:

    OVERFLOW GUARD FAIL — 8 finding(s) in: GR109-attention-row-dead-rule, GR115-bpconsole-dead-rule

All three required lines (dispatcher `console='true'`, the FAIL line, the aggregator's
`FAIL    overflow-guard: failure`) ARE on main — only the expected literal is falsified, by the
GR115 flake the epic already filed as `cch-w19-bl-gr115-intermittent-ua-defaults` (open).

## 7. Two rows claim the same three payees

`cch-w19-s2` c11 closes `cch-w16-bl-trial-chip-truncated-on-every-phone`,
`task-9fcf92e7a02fa5b8`, `cch-w16-bl-theme-picker-select-clipped-at-320` against 87e8726c4 —
while `cch-w17-s-topbar-phone-band-wrap` c9 (open) names the same three, and
`task-9fcf92e7a02fa5b8` c4 pins itself to *w17's* squash SHA, which will never exist. The
collapse must re-point that criterion at 87e8726c4.

## 8. `task-079ef706ee5289c4` is an unpublished orphan

    bp task get task-079ef706ee5289c4 -o json

    doc_id: drafts.task-079ef706ee5289c4   status: draft   parent_id: null   priority: null
    criteria_progress: {"met":0,"total":4}   github.issue: 8899 (synced)

    curl …filter[_id]=task-079ef706ee5289c4  ->  0 documents

It is invisible to the predicate on two counts (draft, and no parent). Both the wish and the
strategic direction cite it as "filed". It is filed on GitHub (#8899), not on the ledger.
