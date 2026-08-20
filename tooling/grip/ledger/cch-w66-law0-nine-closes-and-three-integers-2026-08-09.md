# cch-w66-s4 — Law 0: nine closes, three integers, on each row's own identity (2026-08-09)

Cloud Console hardening wave 66, slice s4. Nine rows that SHIPPED and stayed open are now `done`.
Every number below has its producer. Do not retype a figure without re-running its recipe (D677).

**The stale-open mirror of the fabrication class.** A completion that shipped and left no record is as
unreadable as a fabrication that never shipped — the epic's own board read as if two waves did nothing.

## R0 — the premise that was FALSE, recorded so it is not re-run

D781's twelve-row close list was **not** "never executed". It ran in full 2026-08-09T19:39:08Z–19:39:51Z
by `epic-builder-the-law-0-repayment-twelve-evidence-back` (thirteen rows, incl. cch-w61-s2), and D798
audits it row by row. `cch-w60-s6` is already `cancelled` (confirmed: `_updatedAt` 2026-08-09T19:41:16Z).
**Do not re-derive it.** What was unpaid is the nine rows below — a different set.

## R1 — the nine rows, with the identity that closes them

Short handles do NOT resolve, and `bp search` cannot resolve them either (D799). Resolve full ids by
prefix-filtering `doc_id` out of `bp task ls --all -o json`.

| row (full `doc_id` prefix) | stored `previous_worker` (52-char truncated, copy byte-for-byte) | stored epoch | final criteria | PR | merge sha | compare |
|---|---|---|---|---|---|---|
| `cch-w63-s5-the-resting-state-…` | `epic-builder-the-resting-state-stops-asserting-a-chec` | 8 | 15/15 | #11435 | `26b86142592083f52dec856cd95736e780877971` | ahead |
| `cch-w63-s6-pin-total-scenarios-…` | `epic-reviewer-wave-64` | 8 | 8/8 | #11437 | `6d8f1f1c434fd50f7b8effb5088f8f069afea338` | ahead |
| `cch-w63-s7-the-site-refusal-modal-…` | `epic-builder-the-site-refusal-modal-stops-saying-a-de` | 7 | **7/8** | #11488 | `845388d53a3ebb102987820807394412e63f97e7` | ahead |
| `cch-w63-s8-a-refused-write-…` | `epic-builder-a-refused-write-leaves-a-named-audit-row` | 6 | **12/13** | #11489 | `7326aa4a854c591f9197e2f0cc9560fa9c25f9c8` | ahead |
| `cch-w64-s2-the-red-aggregate-…` | `epic-builder-the-red-aggregate-names-the-job-that-ref` | 7 | 12/12 | #11436 | `6b82ebf1517a9cc10d6d929ea1ee9a8dfcda143b` | ahead |
| `cch-w64-s4-the-seal-predicate-…` | `epic-builder-the-epic-s-own-census-instrument-stops-r` | 6 | 8/8 | #11438 | `a1d27149e75590c5538eb655002ff006483dd704` | ahead |
| `cch-w64-s5-law-0-twelve-closes-…` | `epic-builder-the-law-0-repayment-twelve-evidence-back` | 7 | 12/12 | #11420 | `730c465f0cd55d4de3edff7a68c6dc9ea34cd578` | ahead |
| `cch-w64-s6-the-deferred-pill-…` | `epic-builder-the-deferred-pill-stops-reading-calm-the` | 6 | **13/14** | #11486 | `01ba5a50f9690aa79773dbb48980f5de273ad9ed` | ahead |
| `cch-w65-s2-the-control-plane-…` | `epic-builder-the-control-plane-stops-stamping-a-check` | 6 | 10/10 | #11487 | `02ab46d0f87982a70624fffd672aad48630a624e` | ahead |

**#11486 and #11487 were NOT in the briefed seven-PR gate list** but two of the nine rows wait on them.
Nine rows need nine PRs; the brief's seven omitted the deferred-pill and control-plane merges.

### THREE identities are unreconstructable from their slug, not one

The brief warns about `epic-reviewer-wave-64`. Two more fail the same way, because the worker string was
truncated from an **older title** than the slice now carries:

- `cch-w64-s4-the-seal-predicate-can-read-its-own-roster` → `epic-builder-the-epic-s-own-census-instrument-stops-r`
- `cch-w65-s2-…-stops-stamping-an-unmade-check` → `epic-builder-the-control-plane-stops-stamping-a-check`

A script that derives the worker from the slug fails on **three of nine** and, if it passes a reason,
silently mints an override. Copy the stored string; never rebuild it.

## R2 — the close mechanic (the briefed one is INCOMPLETE)

`Internal.close_holder/2` (:105-123) admits a released row as `:self_resume` only when the closer equals
`previous_worker`. True — but **the stored epoch is not directly usable**. Each lapsed lease had already
reverted its row to `lifecycle=open`, and `bp task stamp` refuses that with `not_in_progress:open`.
Three guards fire in sequence, and all three are correct:

1. `bp task close … --set criteria:=[…]` → **refused**: "criteria flipped in this very close command do
   not count — that would be the closer grading its own homework." Stamp is a separate prior write.
2. `bp task stamp … --met` on a merge-gated row → **refused** `merge_gated_criterion`: a builder flipping
   it "fabricates a done before the PR exists". Needs `--merge-gated` (the lead-closing-the-gate path).
3. `bp task stamp` on a lapsed row → **refused** `not_in_progress:open`.

Working sequence, per row:

    bp task claim <doc_id> <stored previous_worker>          # :self_resume, mints a FRESH epoch (e.g. 8 -> 10)
    bp task stamp <doc_id> <same worker> <fresh epoch> \
      --criterion <gate idx> --criterion-text "<verbatim>" --met --merge-gated --evidence "…"
    bp task close <doc_id> <same worker> <epoch> done "…" \
      [--set criteria_override="<why a named criterion stays met:false>"]

**Identity is what avoids the override; the stored epoch is stale by construction.**

## R3 — read-back: zero `close_override.holder`, three honest `close_override.criteria`

    # per row, from the published perspective
    curl -sG "$BP/v1/data/query/production/task" --data-urlencode 'filter[_id]=<doc_id>' \
      --data-urlencode 'filter[status]=published' -H "Authorization: Bearer $TOK"

Measured after all nine landed: the literal substring `"holder"` is **absent from all nine published
docs**, and every row's `claim.closed_by` equals its own `previous_worker`. `close_override.criteria` IS
present on exactly the three short-closing rows with `actor` = that row's own worker — that is the honest
on-record note for closing over a named unmet criterion, **a different key from `.holder`**. Do not read
its presence as an identity override.

## R4 — the three rows that close short, and why

- **cch-w63-s7 c5** (`no_previous` arm neither reachable nor deleted) — honest miss stamped by its
  builder; stays `met:false`, row done at 7/8. Residue already carried by the OPEN row
  `cch-w65-bl-site-rollback-plane-types-its-box-refusals`.
- **cch-w63-s8 c10** (D746's 36 unlabelled verbs; census arm NOT armed) — honest miss; row done at 12/13.
  Residue already carried by the OPEN row `cch-w65-bl-action-labels-and-actions-are-uncoupled`.
- **cch-w64-s6 c12** — NOT a merge gate (no `merge_gate` marker; only c13 has one) and the roster's only
  criterion carrying an `attempts` key. It was **tested, not assumed**:

      gh pr view 11486 --json body --jq .body | grep -c "D212\|D213\|flip risk\|flip-risk"   # 0

  Unmet **as worded** (it requires the declaration in the PR *body*), so it stays `met:false`. The
  declaration genuinely exists, verbatim, in the MERGED commit message of `01ba5a50f9` — line 43
  "THE PALETTE CALL (high flip risk, stated not hidden)" and lines 55-56 "THE COPY CALL (high flip risk)"
  citing deploy-reliability D212/D213. **Real, on the permanent record, on the wrong surface** → reported,
  not flipped.

No duplicate follow-ups were filed: both residues already had open backlog rows.

## R5 — LEFT OPEN, deliberately (D781/D798)

    cch-w63-s4-the-law-0-repayment-ten-evidence-backed-closes-and-two-integers   open, 5/7, unmet [5,6]
    cch-w38-s1-lifecycle-rail-authority-is-three-valued                          open, 13/15, unmet [2,14]

Untouched by this slice — not claimed, stamped, patched or closed; `close_override` null on both.
s4's unmet criterion is a board-arithmetic miss: its own integers were never re-derived, so closing it
would stamp a count nobody measured — the same fabrication class this wave removes.

## R6 — the three integers, with the truncation guard

    curl -sG "$BP/v1/data/query/production/task" \
      --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
      --data-urlencode 'filter[status]=published' --data-urlencode 'limit=1000' \
      -H "Authorization: Bearer $TOK" | python3 -c "import sys,json,collections;d=json.load(sys.stdin)['result'];print(d['count'],len(d['documents']),collections.Counter(x.get('lifecycle_status') for x in d['documents']),sum(1 for x in d['documents'] if x['_id'].startswith('drafts.')))"

| read | timestamp (UTC) | count == len | drafts. | open | in_progress | done | cancelled | considering | LIVE |
|---|---|---|---|---|---|---|---|---|---|
| at claim | 2026-08-09T23:32:14Z | 874 == 874 | 0 | 433 | 4 | 370 | 66 | 1 | **437** |
| at finish | 2026-08-09T23:45:02Z | 876 == 876 | 0 | 425 | 4 | 379 | 67 | 1 | **429** |

**THIS SLICE: CLOSES 9 · MOVES 0 · SELF-FILED 0.** (Self-filed is 0 on purpose — both honest-miss
residues already had open backlog rows; filing duplicates would inflate the board with visible work.)

### The board fell by 8, not 9 — the difference, not a rounding

`done` rose by exactly **+9** (370→379), and those nine are named with timestamps 23:39:35Z–23:43:56Z.
Two **foreign** movements by sibling wave-66 slices ran inside the same window:

- **−1 LIVE** cancellation: `task-45bb283f60656942` (overflow guard FONT PIN refuses intermittently), 23:39:15Z
- **+2 LIVE** filings: `task-4ab4a5b58bce97a6`, `cch-w66-fu-font-pin-race-has-no-committed-regression-test`

Reconciliation is exact: **437 − 9 − 1 + 2 = 429.**

Against the D808 baseline (866 total / LIVE 429 / self-filed 0): total 866→876 (+10 = wave 66's eight
slice tasks plus the two mid-wave filings); LIVE 429→429 is **FLAT on the raw number**, which is precisely
why LIVE alone is not the score. `LIVE_final − self_filed` = 429 − 10 = **419** against 429 → the real
floor fell by **10** (nine closes plus the foreign cancellation).

**Not compared on `open` alone** (D780's warning): `open` moved 433→425 (−8) while `in_progress` held at
4, so an open-only read would have understated the closes by one and hidden the foreign cancellation.

**HONEST LIMIT ON THE FINISH NUMBER:** it is **mid-wave, not a seal** — `in_progress` is 4 and sibling
builders are still writing. `count == len` and `drafts. == 0` held at 23:45:02Z, but a sibling `patch`
after that instant mints a counted `drafts.` twin and moves it
(`dr-w33-fu-patch-spawns-a-counted-draft-shadow`). Whoever seals wave 66 must re-read on a quiet board
rather than quoting this row as final.

## Traps recorded

1. **The stored epoch is not closable.** A lapsed lease reverts the row to `open`; stamp refuses
   `not_in_progress`. Re-claim on the row's own `previous_worker` first (`:self_resume`) and use the
   fresh epoch. Identity, not epoch, is what prevents the override.
2. **Three of nine worker strings are unreconstructable from their slug** (R1) because the 52-char
   truncation captured an older title. A slug-derived script fails silently on a third of the roster.
3. **`close_override.criteria` ≠ `close_override.holder`.** A read-back that greps for `close_override`
   reports three "overrides" that are honest miss-notes. Grep for the `holder` key specifically.
4. **guerrilla returned intermittent `DBConnection.ConnectionError` 500s** throughout this run (four of
   nine rows failed mid-sequence on the first pass). The driver must be **idempotent and live-reading**:
   re-read each row's published state, skip rows already `done`, skip an already-`met` stamp, and retry.
   A fire-and-forget batch leaves rows claimed-but-unclosed and reports a false partial.
