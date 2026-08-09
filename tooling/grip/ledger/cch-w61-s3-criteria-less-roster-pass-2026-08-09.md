# cch w61 s3 — the criteria-less roster pass (2026-08-09)

Task: `cch-w61-s3-the-criteria-less-roster-pass`. A LEDGER pass: no repo behaviour changed.
This file is the durable record of what was measured and what was moved, so the next reader
re-derives instead of inheriting.

## The population, re-derived (not inherited)

```
bp task get cloud-console-hardening-epic -o json \
  | jq -r '[.children[]|select(.lifecycle_status=="open" and ((.criteria_progress.total//0)==0))]|length'
```

OPENING roster (13:06Z): children **836** — cancelled 61 / considering 1 / done 341 /
in_progress 3 / open **430**. Criteria-less open: **38**.
Across ALL lifecycle states the zero-criteria count is 44 (cancelled 5 + done 1 + open 38) —
44 is the filter slip, 38 is the triage population.

Note on "published-live open": the `.children[]` projection carries only
`{criteria_progress, doc_id, execution_class, inserted_at, lifecycle_status, title}`. There is no
`.status` on a child row, so a published-live count cannot be derived from this shape.

## The trap, one jq path wide

`jq '.doc.description'` is **null for all 38**. The authored body is at `.doc.content.description`
— measured 619–2607 chars, none empty. A pass reading the flat path measures every row empty and
concludes all 38 are wishes. The same trap sits one field over: acceptance criteria live at
`.doc.content.acceptance_criteria`, and the flat read renders as "0 criteria, 0 met",
indistinguishable from a genuine zero.

So the lead's ruling "no criteria = a wish" was CORRECTED, not applied literally: 31 of the 38
bodies name a source file and 14 name a `file:line`. Applying it literally destroys located
mechanisms.

## The durable finding

Criteria-less rows exist ONLY for `inserted_at` 2026-08-06 (3), 08-07 (29), 08-08 (6) — zero before,
zero on 08-09 (this wave's own filing day). 33 of 38 slugs carry the `-bl-` backlog-filing infix.
A bounded, **no-longer-reproducing** authoring regression in the backlog-filing step. A guard against
it must therefore be a CENSUS over FUTURE published rows, not a repair to a step that is behaving —
filed as `cchi-w61-bl-criteria-census-over-future-published-rows`.

## The banding — 19 closed, 19 kept

**(A) Sixteen rows were never this epic's.** Standing Law 0 sends gate / generator / harness /
required-checks / ledger-hygiene rows to `cch-instruments-epic`, filed there *at create time — a
create, never a re-parent*. Each was CANCELLED here with a durable `disposition_reason` naming its
new row, and CREATED there carrying the original body verbatim plus transcribed criteria.

| cancelled under cch | created under cch-instruments-epic |
|---|---|
| cch-bl-protection-claim-paraphrase-escape | cchi-bl-protection-claim-paraphrase-escape |
| cch-w39-bl-audit-the-other-three-packet-instruments-for-vacuous-exits | cchi-w39-bl-audit-the-remaining-packet-instruments-for-vacuous-exits |
| cch-w39-bl-mefault-must-be-exhaustible-or-no-retry-can-be-proven-to-recover | cchi-w39-bl-mefault-must-be-exhaustible |
| cch-w40-bl-newlaunch-plan-limit-row-is-two-thirds-paid-not-a-clean-false-open | cchi-w40-bl-newlaunch-plan-limit-row-is-two-thirds-paid |
| cch-w40-bl-required-checks-apply-is-the-one-packet-instrument-still-unaudited | cchi-w40-bl-required-checks-apply-still-unaudited |
| cch-w40-bl-the-refusal-copy-census-needs-a-verdict-drift-arm | cchi-w40-bl-refusal-copy-census-verdict-drift-arm |
| cch-w46-bl-binding-census-null-pin-decay-arm | cchi-w46-bl-binding-census-null-pin-decay-arm |
| cch-w46-bl-breakpoint-sweep-title-is-a-five-integer-claim-that-cannot-lose | cchi-w46-bl-breakpoint-sweep-title-is-a-five-integer-claim-that-cannot-lose |
| cch-w46-bl-eleven-non-rail-elevated-writes-measured-population | cchi-w46-bl-elevated-writes-column-conflates-three-populations |
| cch-w46-bl-lapsed-claim-arrears-close-path | cchi-w46-bl-lapsed-claim-arrears-close-path |
| cch-w46-bl-rebase-10256-and-rescue-10054-ledger-rows | cchi-w46-bl-rebase-10256-and-rescue-10054-ledger-rows |
| cch-w47-bl-inline-cond-overlay-pairs-route-to-line-by-source-order | cchi-w47-bl-inline-cond-overlay-pairs-route-to-line-by-source-order |
| cch-w51-bl-run-ci-still-declines-to-look-on-enforced-false | cchi-w51-bl-run-ci-still-declines-to-look-on-enforced-false |
| cch-w51-bl-verify-never-checks-its-own-spec-freshness | cchi-w51-bl-verify-never-checks-its-own-spec-freshness |
| cch-w55-s2-followup-app-test-blind-to-gap-copy | cchi-w55-s2-app-test-blind-to-gap-copy |
| task-0eb5f44034887fb1 | cchi-w40-bl-router-tier-census-blind-to-cause-only-refusals |

**(B) Two closed `done` on run proofs.**

* `task-ed706f4e1c616f89` — SHIPPED. Both refusal sentences (`outranked`,
  `cannot_grant_higher_role`) are authored in `FORBIDDEN_REASON_COPY` at
  `cloud/priv/static/app.js:292-293`, with the provenance comment at `:265-280` naming
  `router.ex:4958` / `:4997`; `grep -c` for the two slugs in `cloud/priv/static/__app.test.mjs` = **21**.
* `cch-w56-bl-exclusions-are-overwritten-not-merged` — FULLY superseded. `bash
  scripts/required-checks.test.sh` → **180 passed, 1 failed**; section 14b is **11/11**, including
  "…and EVERY committed exclusion context survives, 'gofmt drift ceiling (blocking)' included
  (26 in, 26 out)" and both mutation arms. The loss mirror is at
  `scripts/required-checks-generate.sh:852-915` (earlier prose said `:882-912` — same block,
  line-shifted). The suite's one failure is unrelated (merge-gates.md docs drift).

**(C) The coin flip — cancelled as a DUPLICATE, not as shipped.**
`cch-w40-bl-modal-oracle-is-an-instrument-no-job-runs`. The finding is LIVE — re-derived here,
`git grep -n modal-oracle -- .github/ scripts/ Makefile` → rc=1, no output. But it is the fourth copy;
`cch-w22-s1-residue-modal-oracle-uninvoked` (open, 5 criteria) is strictly stronger on the same
finding. Two facts it carried that the survivor does not were transcribed into its
`disposition_reason` rather than destroyed:

1. `__unknown_census.mjs` looks unrun to the same basename scan but IS spawned from
   `cloud/priv/static/__app.test.mjs:16774` (the row said `:15135`; the line has drifted — re-derive).
   Any future sweep over the 18 `.mjs` under `cloud/priv/static` must resolve
   `fileURLToPath(new URL(...))` spawns or it files a second false orphan.
2. A CLEARANCE, not work: the Console gate has no dispatch hole a diff could exploit — `CONSOLE_PATHS`
   begins `cloud/priv/static/**` (`scripts/console-path-escape-check.sh:142`), neither
   `console-harness.yml` nor `cloud.yml` carries a workflow-level `on: paths:` filter, `decide()`
   accepts `skipped` only against a gate value of exactly `false`, and a D377 tally emits
   `::notice title=Console gate: green — nothing ran::` when `dispatched==0`.

**(D) Nineteen rows kept, with criteria transcribed from their own bodies** — 60 criteria over 19
rows, each quoting the `file:line`, sequencing gate or mutation proof that row's body already names.

## Closing roster (re-derived, not arithmetic)

children **838** — cancelled 78 / considering 1 / done 343 / in_progress 4 / open **412**.
Criteria-less open: **0** (was 38).

Net open **430 → 412 = −18**. This pass removed **19** open rows (16 forwards + 1 duplicate + 2 done);
the roster shows −18 because concurrent wave-61 slices added a row (children 836 → 838) — which is
exactly why the number is quoted from a second measured roster and never computed off the first.

CLOSED 19 · AUTHORED 16 new published rows (49 criteria) + 60 criteria onto survivors + 1 follow-up
row = **109 criteria authored, 0 rows destroyed**.
