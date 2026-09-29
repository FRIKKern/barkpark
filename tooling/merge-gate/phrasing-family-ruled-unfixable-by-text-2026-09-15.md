<!-- doc-tier: cold | canonical-for: merge-gate-phrasing-family-ruling | budget: 1200tok -->
# The `PR merged (lead closes)` family is RULED OUT of the authoring nag — unfixable by text

Measured 2026-09-15 by `scripts/merge-gate-backfill.mjs --twice` against the live
ledger. Criterion 4 of `bl-merge-gate-backfill-enumeration-unsound` offered two
doors: bring the family into the AUTHORING nag, or rule it out. **Ruled out.**

## The measurement that is the reason

The row was filed on this number: of the 135 unflagged rows the 2026-08-23
residue pass found, **99 (73%)** were this phrasing — `PR merged (lead closes on
merge)` and kin — and the leading-anchored nag saw none of them. Reproduced on a
live three-criterion probe row: the engine named `[0]` (leading marker) only, and
was silent on `[1]` (`PR merged (lead closes on merge)`) and `[2]` (`PR merged to
main with all four required contexts green. LEAD closes.`).

Today's live census over the 917 open rows (3,054 criteria):

| bucket | all | unflagged (= residue) |
|---|---|---|
| `merge_gate: true` | 222 | — |
| leading `MERGE-GATED` marker (the nag sees these) | 172 | 6 |
| `PR merged … lead closes` family (the nag cannot) | 48 | 2 |
| criterion mentions a merge at all | 374 | — |

The 48 is a true number with a false story on its own: 46 of them already carry
the flag. The residue the nag is blind to is **2 criteria**, not 48.

## Why widening the nag is refused

`@merge_gate_lead` (api/lib/barkpark/plugins/tasks.ex) carries an in-tree
prohibition with its own census behind it: of 1,845 marker-bearing criteria,
1,740 are leading, **51 are non-leading and genuine**, and **54 merely MENTION
merge-gating and were never gates**. Position and prose misclassify in OPPOSITE
directions, so no text rule separates the 51 from the 54. A widened nag pays ~54
false nags to catch ~51 real ones — and the same regex is shared with the `bp
task stamp` REFUSAL, where a false positive lets a builder fabricate a merge
close. The asymmetry that makes a miss free at the nag does not survive the
shared regex.

## What replaces it

Not a text rule — a REPORT. `scripts/merge-gate-backfill.mjs` classifies the
family as its own named category, `PHRASING-FAMILY`, separate from `FLAGGABLE`,
and never writes it. The gap stops being invisible without the nag having to
guess. The 2-criterion residue is a human decision on 2 rows, not a regex.

Fenced out of this change deliberately: the nag lives under `api/`, outside the
gates lane's fence. If an owner overturns this ruling, the change is one regex in
`tasks.ex` plus the `bp task stamp` refusal it shares — not a backfill.
