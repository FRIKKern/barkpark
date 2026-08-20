# cch-w22-s6 — Law 0 executed: 23 rows disposed against the seal predicate's OWN denominator

Slice: `cch-w22-s6-law0-executes-the-23-row-repayment` · executed 2026-08-02 · ships NO product code.

Law 0 had slipped six consecutive waves (66 → 84 → 89 → 85 → 93 → 103) and wave 21 read **94 live against
wave 20's 85** — the epic netting POSITIVE, which the law prohibits. This receipt is the re-runnable record of
the repayment: what was disposed, in what order, against which denominator, and what the number actually did.

---

## THE RULE — stamp `orphans`, never `residue`

A wave stamps `orphans=` off the `VERDICT-TOKEN` line, at FIRST CLAIM and at DEBRIEF, and never mixes the two.
Four mechanical reasons, all readable in `cloud/priv/static/__preview__/seal-predicate.mjs`:

1. `orphans` is the only figure emitted in a machine-parsable token.
2. Clause (a) tests `orphans.length === 0` (`:508`) — `orphans` IS the seal condition; `residue` is not.
3. `orphans = residue − PERMANENT_HUMAN_GATES − forwarded` (`:366-371`), both subtrahends structural
   constants, so `Δorphans ≡ Δresidue`: they can never disagree on DIRECTION.
4. The constant level gap between them **is the phantom**. Quoting `residue` at first claim and `orphans` at
   debrief manufactures a delta nobody paid.

`bp task get`'s child count is quotable for nothing: it includes `drafts.*` rows that the predicate's
published-only roster query (`fetchRoster`, `:346`) cannot see.

```sh
# THE denominator. Re-read it yourself; never carry a number from a brief.
node cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic 2>&1 \
  | grep -E 'VERDICT-TOKEN|roster:|UNNAMED RESIDUE'
```

---

## MEASURED, BOTH ENDS

| | read at | roster | residue | **orphans** |
|---|---|---|---|---|
| first claim | `2026-08-02T05:44:18.201Z` | 275 children | 110 | **107** |
| after disposal | `2026-08-02T06:14:39.914Z` | 282 children | 93 | **90** |

```
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=107 considering=1 successor=cch-instruments-epic epic=cloud-console-hardening-epic mode=live stubbed=0 waived=0
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=90  considering=1 successor=cch-instruments-epic epic=cloud-console-hardening-epic mode=live stubbed=0 waived=0
```

**Δ = −17. The epic netted NEGATIVE.** Reconciled row by row, not asserted:

| | rows | |
|---|---|---|
| −24 | disposed by this slice | 23 from the executable list + `cch-w18-bl-wrap-recipe-fourth-host-extract` by AMENDMENT. Verified by post-condition read: none of the 24 is in `open`/`in_progress`. Corroborated by counts — `done` 139→159 (+20), `cancelled` 26→30 (+4). |
| +3 | filed forward by this slice | the criteria it refused to flip, made visible: `cch-w22-bl-chip-guard-blind-below-721`, `cch-w22-bl-url-remedy-candidates-never-priced`, `cch-w22-bl-attention-sibling-never-measured` |
| +4 | filed by OTHER wave-22 builders mid-run | `cch-email-format-missing-u-modifier`, `cch-rtl-script-neutral-borrowing`, `cchi-w22-bl-shared-modal-card-min-content-floor`, `task-696a2fcf95e9c4da` |

`107 − 24 + 3 + 4 = 90`. Exact; no unexplained row.

**Stated plainly: 90 is NOT below wave 20's 85.** The brief's "99 − 23 = 76, clearing 85 with margin" was
computed against a 99 that no longer existed — wave 22 had already filed its own eight slices (99 → 107)
before a single disposal, and kept filing while the disposals ran. Direction right, floor not cleared.

**The denominator MOVES while you read it.** The gate re-run at the end of this slice already printed
`orphans=92` against a 284-child roster — two further rows filed by concurrent builders in the intervening
minutes. So the honest unit is not the absolute number but the **delta attributable to a slice across its own
window**: −24 disposed, +3 filed forward, measured at both ends by the same command. Any wave quoting a bare
`orphans` figure taken under concurrent load is quoting the LOAD as much as the ledger — read it twice, and
reconcile the difference by row, exactly as the table above does.

---

## ORDER OF OPERATIONS — it is load-bearing

`bp` refuses a close whose criteria are flipped inline: *"criteria flipped in this very close command do not
count — that would be the closer grading its own homework."* Every flip is therefore a **separate stamp taken
before its close**. And all eleven merge-gated rows read `claim.worker = null` with a lapsed `expired_at`, so:

```sh
# CLAIM FIRST — `release` is the wrong verb for a lease that has already lapsed.
bp task claim <id> <worker>                      # -> doc.claim.epoch (a NEW, higher epoch)
bp task stamp <id> <worker> <NEW-epoch> --criterion N \
     --criterion-text "<the row's exact wording>" --met --evidence "…" [--merge-gated]
bp task close <id> <worker> <NEW-epoch> done "…" [--set criteria_override="…"]
```

`--merge-gated` was passed only where the SHA had already printed `ANCESTOR`. Note the guard is a substring
check on the criterion TEXT, so it also fires on a criterion merely *about* merge-gated rows.

### Ancestry loop — every SHA, before any close

```sh
git fetch origin main
for s in 87e8726c4 367e19810 405f6ebae 3c6d1540a 99ea46c1b c25466dac \
         974d412ca 3cf1285e3 4864edc14 6d167cf8a b0fa685fe; do
  printf '%s ' $s
  git merge-base --is-ancestor $s origin/main && echo ANCESTOR || echo NOT
done
```

Result: **eleven ANCESTOR, zero NOT.**

---

## THE 24 DISPOSED

**A — eleven closes**, each carrying exactly one unmet criterion and it was the merge gate:

| row | was | SHA | PR |
|---|---|---|---|
| `cch-w19-s2-topbar-phone-band-620` | 10/11 | `87e8726c4` | #8945 |
| `cch-w19-s4-wrap-parity-e14` | 10/11 | `367e19810` | #8946 |
| `cch-w20-s3-instance-card-url-bounded` | 10/11 | `405f6ebae` | #8984 |
| `cch-w20-s6-attention-row-wrap` | 11/12 | `3c6d1540a` | #8985 |
| `cch-w20-s7-op-gate-one-declaration` | 9/10 | `99ea46c1b` | #8988 |
| `cch-w20-s8-band-a-shell-fold-cliff` | 11/12 | `c25466dac` | #8986 |
| **`cch-w20-s9-attention-name-column-collapse`** | 10/11 | `974d412ca` | #8987 — **D250 OMITS IT** |
| `cch-w21-s1-members-roster-identity-and-remove` | 9/10 | `3cf1285e3` | #9057 |
| `cch-w21-s2-detail-head-320-copy-offscreen` | 8/9 | `4864edc14` | #9058 |
| `cch-w21-s3-cruel-fixture-fleet-url-and-card-name` | 10/11 | `6d167cf8a` | #9059 |
| `cch-w21-s4-token-reveal-readable` | 9/10 | `b0fa685fe` | #9060 |

**B — four cancels**, superseded, MIGRATE-BEFORE-CANCEL on every one:

`cch-w19-s3` → `cch-w20-s3` · `cch-w19-s6` → `cch-w20-s6` · `cch-w19-s7` → `cch-w20-s7` · `cch-w19-s8` → `cch-w20-s8`

`cch-w19-s7` carried **four unique criteria**, migrated onto the survivor's criteria 1/2/3/5 as dated
`[MIGRATED 2026-08-02 …]` clauses (`bp doc patch` + `bp doc publish`, rev `982d445f66ac5f1e36f043f08b4f9615`)
and **verified by read-back before the cancel was issued**: the 546→446 shell-fold mechanism (carried,
unmeasured); the driven refutation of the five-declaration recipe (carried AND paid by D220); the vertical
assertion + height cost (cost paid by D220, assertion carried as unmet); the 740-800 re-entry mutation cell
(carried as a quotation gap). The other three rows' unique content is preserved in their `criteria_override`.

**C — eight cascade closes**, named inside those gate texts, each with evidence WRITTEN INTO ITS CRITERIA:

`cch-w16-bl-trial-chip-truncated-on-every-phone` · `task-9fcf92e7a02fa5b8` ·
`cch-w16-bl-theme-picker-select-clipped-at-320` · `cch-w18-bl-instance-card-url-ellipsised-on-phone` ·
`task-802585b77fc136b1` · `cch-w18-bl-tablet-attention-row-worst-cell-misnamed` ·
`cch-w17-bl-op-gate-pill-paints-outside-chip` · `cch-w17-bl-band-a-shell-fold-cliff`

These were at 0/N with substantive criteria. **Seven criteria across them were honestly LEFT UNMET rather
than flipped**, each named in a `criteria_override` on its own close and forwarded to a published row. Closing
them at 0/N with empty evidence would have re-created the false-done pattern this epic already paid for.

---

## D250 IS WRONG IN BOTH DIRECTIONS

**It OMITS `cch-w20-s9`.** `#8987` landed as `974d412ca` after being stuck across three waves; it is an
ancestor and its row had the same 10/11-plus-merge-gate shape as the other ten.

**It INCLUDES `cch-w19-bl-op-gate-dot-centring-at-320`, which is UNPAYABLE. That row STAYS OPEN.**

```sh
git show 99ea46c1b -- cloud/priv/static/app.css > /tmp/d.diff
grep -c align-items /tmp/d.diff        # -> 0
grep -n '^+\..*{'   /tmp/d.diff        # -> +.op-gate .status-pill { flex: 0 0 auto; }
```

Its criterion 1 requires an ADD of `align-items: flex-start` scoped to `.op-gate`. The shipped remedy contains
no `align-items` at all — it is a different declaration solving a different defect (the pill narrower than its
own label, not the dot's cross-axis alignment). Closing it against that SHA would be a fabricated done.

The two errors **do not cancel**: one row added, one removed, so D250's count survived while both of its
members were wrong. That is exactly what a mixed quote produces.

---

## TWO ROWS RULED, OUTSIDE THE EXECUTABLE LIST

**`cch-w18-bl-wrap-recipe-fourth-host-extract` — disposed by AMENDMENT, never a cancel** (as `cch-w20-s7`'s
gate text (c) instructs). Its criterion 0 admits *"or the extraction is refused in writing with its reason"*,
and charter **D220 IS that refusal**:

```sh
# Read origin/main, NOT the on-disk charter — this wave's charter is an open PR,
# so the local copy is the PREVIOUS wave's and will read plausible while being stale.
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/c.md
grep -c '^| D220 ' /tmp/c.md           # -> 1
```

Criteria 1-3 are **MOOT** — each opens with "If extracted" — and each now says so on its own text.

**`cch-w14-bl-billing-chip-truncated-above-768` — LEFT OPEN, deliberately.** Both paying SHAs are recorded on
the row via `bp task stage <id> open --disposition open --note … --rerun …` (the same-state adjudication edge,
which records a disposition without reopening or moving the row): 769-830 by `626466a0c` (#8851), 721-740 by
`c25466dac` (#8986). Closing it means stamping four criteria from two PRs, and its criterion 0 is a RULING
criterion — an adjudication, which `cch-w20-s8`'s own gate text forbids blanket-disposing in either direction.

---

## THE FOUR DRAFT DISCARDS BUY EXACTLY ZERO

Hygiene, never repayment — and the mechanism is why, not the intent:

`do_discard_draft/4` (`api/lib/barkpark/content/lifecycle.ex:605` — **not :446, which is
`criteria_regression_error/1`**) computes `DraftId.draft_id(published_doc_id)`, gets that ONE row and
`fenced_delete`s it. It never reads, requires or mutates a published twin: twin state is not an input.
And the predicate's roster is a **published-only** query (`:346`), so no `drafts.*` row is in the count.

Proven by observation, not only by reading: after the four discards, `cch-w21-s4-token-reveal-readable` still
reads `done` and `cch-w19-s1-guard-loses-in-ci` still reads **`open`** — still counted in the residue.

Discarded: `cch-w21-s4-token-reveal-readable`, `cch-w19-s1-guard-loses-in-ci`,
`cch-bl-required-checks-floor-blind-uncalled`, `cch-bl-floor-is-blind-and-uncalled`.

**Deviation, recorded:** the raw query returned SIX drafts, not four (and SEVEN by the post-discard read). The
extras are other wave-22 builders' live work — `drafts.cch-w22-s2-site-row-name-and-host-bounded` and the
`drafts.zz-probe-w22s3*` probes. They were deliberately NOT discarded; clobbering a concurrent builder's open
draft is not hygiene.

```sh
# Drafts are invisible to the predicate. Compare the two perspectives to see it:
bp doc query task --filter "parent_id=cloud-console-hardening-epic" --limit 500 --perspective raw -o json
```

---

## WHAT THIS ROW REFUSED TO CLAIM

- **The floor is not cleared.** 90 > 85. Direction right, margin absent.
- **Seven criteria stayed `met=false` on rows that closed `done`**, each named in a `criteria_override` and
  forwarded to one of the three new rows. A close is not a proof.
- **`cch-w19-bl-op-gate-dot-centring-at-320` stays open** and is not in the 23.
- **`cch-w14-bl-billing-chip-truncated-above-768` stays open**; closing it is an adjudication, not a disposal.
