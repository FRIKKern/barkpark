<!-- doc-tier: agent | canonical-for: merge-gate-retired-quote-rearm | budget: 1200tok -->
# Quoting a retired merge gate RE-ARMS the prose arm

A retraction quotes what it retracts, so it matches its own retraction.

## The mechanism

`Criteria.merge_gated?/1` (api/lib/barkpark/tasks/criteria.ex:107) reads the
structural `merge_gate` key first and falls back to prose when the key is
ABSENT — `@merge_gate_worded = ~r/MERGE[-\s]GATED|MERGE[-\s]GATE\b/i`
(criteria.ex:122). The fallback reads the WHOLE criterion. It does not know what
a quotation is.

So when an author RETIRES a gate by rewriting the criterion around it:

```
CORRECTED 2026-08-20 by the board-reconciliation audit. ORIGINAL WORDING,
verbatim: "PR merged into jarl-website main (merge-gated; the lead closes this
criterion).". THAT CRITERION CAN NEVER BE MET AS WRITTEN … THE CORRECT
REQUIREMENT: the work must be BUILT and verifiably present on main, confirmed
by reading the tree, NOT by a merge notification.
```

…the marker survives inside the quotation, the prose arm still fires, and the
builder still cannot stamp. The correction re-armed the tripwire it was undoing.

It is worse than a no-op, because the two readers are ASYMMETRIC:

| reader | file | reads | verdict on the corrected criterion |
|---|---|---|---|
| stamp refusal | `criteria.ex:107` `merge_gated?/1` | flag **OR** prose — wide | GATE → builder refused |
| close autostamp | `close.ex:1710` `merge_gate_synthetics/3` | `merge_gate == true` **only** — strict | not a gate → lead never autostamped |

The wide arm refuses the builder; the strict arm will not stamp it for the lead.
Nobody can stamp it. `check_criteria_proven/4` returns `{:criteria_unmet, [i]}`
and the row closes only on a loud override.

## How to quote a retired gate without re-arming it

**Set `"merge_gate": false` on the criterion.** It is the documented one-field
veto (criteria.ex:77-81), it beats the prose arm outright, and it leaves the
quotation byte-identical.

**Do NOT reword the quote to dodge the regex.** The verbatim quote is the
evidence the correction exists for; a paraphrased quote is a falsified record.

**Do NOT reach for `bp task stamp --merge-gated`.** That override asserts the
criterion IS a gate and is recorded as an assertion (`verified: false`) — it
makes the ledger less true at exactly the moment the author is stuck, which is
why the veto exists instead.

## The rule, not the list

Six `jf-w1-*` criteria were corrected this way on 2026-08-20. Five have since
closed; only `jf-w1-revendor-honest-media#4` was still non-terminal on
2026-09-17. A named list of six would already be wrong, so the durable form is a
PREDICATE — `quotesRetiredGateOnly()` in `scripts/merge-gate-backfill.mjs`:

> strip every quoted span; if the marker no longer matches, every match it had
> was borrowed from the quotation, and the criterion is a MENTION, not a gate.

It is exercised by the `RE-ARM:` arms of `node scripts/merge-gate-backfill.mjs
--selftest`, including the negative case (a criterion that declares a gate AND
quotes something else is still a gate).

## Why the readers are not the fix

Both readers are correct as they stand and neither is being changed. The wide
arm's false positives are LOUD and per-row fixable; a narrowed arm's false
negatives would be SILENT permits letting a builder fabricate a lead's merge
close. That asymmetry is measured and twice-refuted in the `merge_gated?/1`
moduledoc. The remedy is the flag on the criterion, not a change to the guard.
