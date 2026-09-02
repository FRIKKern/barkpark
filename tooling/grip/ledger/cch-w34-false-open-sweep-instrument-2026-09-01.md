# cch-w34 — the false-open sweep becomes an instrument (2026-09-01)

Row `cch-w34-bl-false-open-sweep-instrument-fails-silent-empty`, charter D391. The
"standing sweep" was four ledger notes describing a hand-typed pipeline; it is now
`scripts/false-open-sweep.mjs` with `--selftest` over 12 committed fixture cases.
**No task was closed by this run.** The script has no write path to the ledger.

## The live run

```
env -u BARKPARK_TOKEN node scripts/false-open-sweep.mjs \
  --epic cloud-console-hardening-epic --status open --since 2026-07-01 --cache-dir <dir>
```

```
false-open-sweep · live · 2026-09-01T22:27:40.536Z
epic: cloud-console-hardening-epic
roster: WALKED 927/927 children (server child_count 927) — COMPLETE
population: 242 rows with lifecycle_status=open
merged-PR window: 4273 PRs over 5 SERIAL page(s)
    merged:>=2026-07-01                        -> 1000
    merged:2026-07-01..2026-08-18T04:08:44Z    -> 1000
    merged:2026-07-01..2026-07-30T03:37:06Z    -> 1000
    merged:2026-07-01..2026-07-16T01:49:23Z    -> 1000
    merged:2026-07-01..2026-07-02T14:37:20Z    ->  277
arm-B coverage: 241/242 rows carry acceptance_criteria — 1 carries NONE
RESULT: 11 of 242 open rows carry a merge receipt  (FULL 2 · PARTIAL 9)
merge-receipt rate: 11 of 242 = 4.5%   <- A FLOOR, NOT AN ESTIMATE
```

Wave 34 read 5 of 109 = 4.6% on a smaller roster. The rate is stable; the population
more than doubled.

### FULL — every unmet criterion is one a merge receipt can pay (2)

| row | met | receipt |
|---|---|---|
| `cch-w40-bl-the-send-test-email-button-answers-yes-when-the-answer-may-be-no` | 9/10 | #10646 `8f109bcac40c` |
| `cch-w77-s1-epic-close-ruling-paper` | 4/5 | #12095/6/7/8, #10006, #12158 |

### PARTIAL — paid in part, NOT CLOSEABLE (9)

`cch-w19-bl-op-gate-dot-centring-at-320` (0/7, #8988) ·
`cch-w40-bl-billing-is-owner-is-honest-only-by-position-after-10005` (0/3, #10005) ·
`cch-w40-bl-ten-live-inline-no-team-emitters-still-diverge-from-the-gates` (0/6, #9956) ·
`cch-w56-bl-backup-dr-runbook-asserts-an-rpo-nothing-schedules` (2/4, #13216 trailer) ·
`cch-w61-bl-cch-w58-s2-carries-four-criteria-its-own-review-declared-false` (0/4) ·
`cch-w61-bl-the-merge-gate-attestation-names-the-wrong-required-set` (0/4) ·
`cch-w63-s4-the-law-0-repayment-ten-evidence-backed-closes-and-two-integers` (5/7, #11379 trailer) ·
`drafts.cch-w64-s5-law-0-repayment-twelve-closes-three-integers` (0/12) ·
`task-f82c05eed177b3ab` (1/2)

The report names each unpaid criterion inline. Closing any of these on the receipt
alone would stamp unbuilt work as done.

## The instrument caught two of its own faults on its FIRST live run

Both were invisible to reading and to the fixtures; only the real 243-row roster
produced them.

1. **A criteria-less row is not a failed fetch.** The first run REFUSED the entire
   population over `task-85c531c2adbf0dff` — open, published, carrying no
   `acceptance_criteria` at all. A legitimate ledger state. A guard that reds on
   correct data gets worked around, so such rows are now counted and DECLARED as
   arm-B-blind coverage; only a missing, zero-byte, unparseable or wrong-id envelope
   still refuses. Pinned by `case-criteria-less-row-is-not-a-fetch-failure`.

2. **A citation is not a receipt.** `cch-w40-bl-billing-is-owner-is-honest-only-by-
   position-after-10005` is 0/3 and names #10005 because #10005 is the merge that
   CREATED its defect. Crediting that inflated the floor with wholly-unbuilt rows:
   **20 of 243 before the split, 11 of 242 after**, and 8 of the rows that fell out
   had no receipt from any arm. Arm B now credits only a criterion that IS the merge
   criterion. Pinned by `case-citation-is-not-a-receipt`.

## Its own findings closed while it ran

Between the two live runs (17 minutes apart) `lead-reconcile-2` closed
`cch-w37-bl-eighteen-curated-messages-break-grammar` and
`cch-w53-bl-state-the-25s-revocation-bound-in-the-signout-copy` — the two rows the
earlier run reported as FULL at 3/3 criteria met with an arm-A trailer receipt. Both
were genuinely false-open. The roster moved 243 -> 242 -> 241 -> 242 across the
session; any count from this instrument is a measurement with a timestamp.

## Corrections to the recipes the earlier notes leave standing

**`gh pr list --search ... --limit 1500` silently returns 1000.** `--search` is served
by the GitHub SEARCH API, which caps at 1000 results and says nothing about it. The
w34 note's one-liner reports 1000 of the 4273 merged PRs since 2026-07-01 — 23% — and
its oldest visible PR today is **#12159**, so it cannot see #8394, #8500 or #9356, the
three receipts that note itself records. The script pages backwards by merge date and
refuses (`PR_WINDOW_TRUNCATED`) rather than reporting a floor from a partial window.

**`children` is a top-level key**, a sibling of `doc`. Confirmed live: the envelope's
top-level keys are `child_count, children, doc, ok`, `child_count` = `children.length`
= 927, and `doc` has no `children`. The script refuses `ROSTER_NO_CHILDREN_KEY` and
says where the key actually is.

**Ambiguous trailers.** 23 merged PRs in the window carry 2+ distinct `Task:` trailers.
`scripts/pr-task-gate.sh` refuses those rather than picking by position; the sweep
mirrors the refusal and counts them instead of crediting a guess.

**The prose arm needs context.** 68 readable prose mentions and 1 NEGATION in the
window — #11340, "**It does NOT close `cch-w59-bl-three-state-reachability-refusal-is-
unmeasured`.**" A naive grep for the slug scores that as a hit. Arm C reads the
sentence, marks it NEGATED, and is excluded from every count either way.

## Re-derivation

```sh
node scripts/false-open-sweep.mjs --selftest        # 12 cases · 80 assertions · exit 0
env -u BARKPARK_TOKEN node scripts/false-open-sweep.mjs --epic <epic> --since 2026-07-01
```

Serial row fetches take ~15 minutes for 242 rows and retry on the intermittent 500s
(3 rows needed 2-3 attempts this run). A parallel fetch is what wrote 15 empty files
in wave 34; empties are refused here, never skipped.
