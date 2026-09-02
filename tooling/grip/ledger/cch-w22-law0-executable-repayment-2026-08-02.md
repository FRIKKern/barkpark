<!-- doc-tier: cold | canonical-for: cch-wave-22-law0-repayment-recipe | budget: 6000tok -->

# Law 0 — wave 22 executable repayment list (re-derivation recipe)

> HISTORICAL RECORD (2026-08-02) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Derived 2026-08-02T04:57:42Z at the Verify phase of wave 22. Nothing here is a
number to quote; everything here is a command to re-run.

## The denominator, and the RULE

```
node cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic
```

prints, on the live ledger:

```
roster: 267 children  {"open":101,"done":139,"cancelled":26,"considering":1}
CLAUSE (a) forwarding — residue 102 (live 101, considering 1)
  UNNAMED RESIDUE (orphans) : 99
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=99 considering=1 …
```

**RULE — a wave stamps `orphans=` off the VERDICT-TOKEN line, at first claim and
at debrief, and never mixes it with `residue`.** Reasons, all mechanical:

1. `orphans` is the only figure emitted in a machine-parsable token.
2. Clause (a) tests `orphans.length === 0` (`seal-predicate.mjs:508`) — it is the
   seal condition. `residue` is not.
3. `orphans = residue − PERMANENT_HUMAN_GATES − forwarded` (`:366-371`), and both
   subtrahends are structural constants (3 hardcoded gates; `forwarded` is
   provably always 0, D249). So `Δorphans ≡ Δresidue` — the two can never
   disagree on direction, only on level.
4. The 3-row level gap IS the phantom: quoting `residue` at first claim and
   `orphans` at debrief manufactures a −3 that nobody paid. That is exactly the
   error the wish is complaining about.

`bp task get cloud-console-hardening-epic` reports **271 / open 103** — do not
quote it. The +4 is exactly the four `drafts.*` rows, which the published-only
query the predicate uses cannot see.

## Payable set — 23 rows, no adjudication

Every SHA below is an ancestor of `origin/main`:

```
for s in 87e8726c4 367e19810 405f6ebae 3c6d1540a c25466dac 99ea46c1b 974d412ca \
         3cf1285e3 4864edc14 6d167cf8a b0fa685fe; do
  printf '%s ' $s; git merge-base --is-ancestor $s origin/main && echo ANCESTOR || echo NOT
done
```

### A — 11 CLOSES (single unmet criterion, and it is the merge gate)

| row | at | SHA | PR |
|---|---|---|---|
| cch-w19-s2-topbar-phone-band-620 | 10/11 | 87e8726c4 | #8945 |
| cch-w19-s4-wrap-parity-e14 | 10/11 | 367e19810 | #8946 |
| cch-w20-s3-instance-card-url-bounded | 10/11 | 405f6ebae | #8984 |
| cch-w20-s6-attention-row-wrap | 11/12 | 3c6d1540a | #8985 |
| cch-w20-s7-op-gate-one-declaration | 9/10 | 99ea46c1b | #8988 |
| cch-w20-s8-band-a-shell-fold-cliff | 11/12 | c25466dac | #8986 |
| cch-w20-s9-attention-name-column-collapse | 10/11 | 974d412ca | #8987 |
| cch-w21-s1-members-roster-identity-and-remove | 9/10 | 3cf1285e3 | #9057 |
| cch-w21-s2-detail-head-320-copy-offscreen | 8/9 | 4864edc14 | #9058 |
| cch-w21-s3-cruel-fixture-fleet-url-and-card-name | 10/11 | 6d167cf8a | #9059 |
| cch-w21-s4-token-reveal-readable | 9/10 | b0fa685fe | #9060 |

All eleven read `claim.worker = null` with `expired_at` in the past — each needs
`bp task claim` FIRST, then `bp task close <id> <worker> <NEW epoch>`.

### B — 4 CANCELS commanded by those same gate texts (superseded, 0/N, nothing to stamp)

`cch-w19-s3-instance-card-url-bounded` (by w20-s3) ·
`cch-w19-s6-attention-row-wrap` (by w20-s6) ·
`cch-w19-s7-op-gate-one-declaration` (by w20-s7) ·
`cch-w19-s8-band-a-shell-fold-cliff` (by w20-s8).

### C — 8 CASCADE CLOSES named inside the gate texts, each verified still open

| cascade row | paid by |
|---|---|
| cch-w16-bl-trial-chip-truncated-on-every-phone | 87e8726c4 |
| task-9fcf92e7a02fa5b8 | 87e8726c4 |
| cch-w16-bl-theme-picker-select-clipped-at-320 | 87e8726c4 |
| cch-w18-bl-instance-card-url-ellipsised-on-phone | 405f6ebae |
| task-802585b77fc136b1 | 3c6d1540a |
| cch-w18-bl-tablet-attention-row-worst-cell-misnamed | 3c6d1540a |
| cch-w17-bl-op-gate-pill-paints-outside-chip | 99ea46c1b |
| cch-w17-bl-band-a-shell-fold-cliff | c25466dac |

## Payable with one written ruling each — 2 more

- `cch-w18-bl-wrap-recipe-fourth-host-extract` (0/4): its criterion 0 admits "or
  the extraction is refused in writing with its reason", and D220 IS on
  origin/main (`git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -c '^| D220 '` → 1).
  Criteria 1-3 are all conditioned on "if extracted" and are moot on a refusal.
  Dispose by AMENDMENT, per w20-s7's own gate text — never by cancel.
- `cch-w14-bl-billing-chip-truncated-above-768` (0/5): BOTH halves are now paid —
  769-830 by 626466a0c (#8851, which also records that the row's "769-820" band
  overstates the edge) and 721-740 by c25466dac. Closing it means stamping c0-c3
  from two PRs; that is an adjudication, so it sits outside the executable list.

## NOT payable — D250 over-counted by two

- **`cch-w19-bl-op-gate-dot-centring-at-320` is 0/7 and its remedy did not ship.**
  Its criterion 1 requires an ADD of `align-items: flex-start` scoped to
  `.op-gate`. `git show 99ea46c1b -- cloud/priv/static/app.css | grep -c align-items`
  → **0**; the shipped remedy is `.op-gate .status-pill { flex: 0 0 auto; }`.
  Criteria 0-5 are unmet substantive work. It stays open.
- `cch-w19-s1-guard-loses-in-ci` is 7/9: criterion 2 (the RED run's three verbatim
  log lines) is unmet and is not merge-gated.

## The four drafts, and why discarding them buys nothing

```
bp task get cloud-console-hardening-epic -o json   # 271 children, 4 doc_id ~ ^drafts\.
```

`drafts.cch-bl-floor-is-blind-and-uncalled` (cancelled) ·
`drafts.cch-bl-required-checks-floor-blind-uncalled` (cancelled) ·
`drafts.cch-w19-s1-guard-loses-in-ci` (open) ·
`drafts.cch-w21-s4-token-reveal-readable` (open).

The two cancelled ones have **no published twin at all** — not a cancelled one:

```
curl -sG "$BP_SERVER/v1/data/query/production/task" \
  --data-urlencode 'filter[_id]=cch-bl-floor-is-blind-and-uncalled' -H "Authorization: Bearer $BP_TOKEN"
# -> "count":0
```

`do_discard_draft/4` (`api/lib/barkpark/content/lifecycle.ex:446`) reads only
`DraftId.draft_id(published_doc_id)` and `fenced_delete`s that one row. It never
reads, requires or touches a published twin, so behaviour is **identical** on all
four regardless of twin state or twin status. And because the predicate's roster
is a published-only query, none of the four is in the 99 — **all four discards
move `orphans` by exactly 0.** Discard them for hygiene, never quote them as
repayment.

## Arithmetic

`orphans 99` − 23 (A+B+C) = **76**, before any wave-22 filing and before the two
ruled rows. Wave 20's 85 and the wish's 94 are both cleared with margin.
