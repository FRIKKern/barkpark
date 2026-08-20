# pbw-stier-field-number — React surface false-done (partial) — 2026-08-18

REOPENED by verifier `field-number-reopen` on the PD Block-Wishlist done-set audit.

## Claim
Task `pbw-stier-field-number` (parent `pd-block-wishlist-epic`) was closed done with
criterion 1 marked `met:true`: *"field-number renders with an honest empty state across
Elixir, Go/TUI, and React."* Its evidence asserts *"PR #4192 / fa7025077 adds compose.ex,
internal/pdrender/field_number.go with tests, **React emitter support**, and tier
registration."* The React clause is FALSE on origin/main: no field-number React emitter
exists; React degrades the block to the `bp-unknown-block` "Unsupported block: field-number"
placeholder. Ships 3-of-4 real surfaces (Elixir + Go/TUI render; React does not).

## Re-derive (origin/main, not the stale local checkout)
```
git fetch origin main -q
git grep -niE 'field-?number|fieldNumber' origin/main -- js/packages/react/src/   # EXIT 1 (absent)
git show origin/main:js/packages/react/src/blocks/forms.ts | tail -1              # export = {form, questionnaire} only
git show origin/main:js/packages/react/src/blocks/registry.ts | sed -n '44,49p'  # unknown type -> "Unsupported block: ${type}"
git grep -l  -niE 'field.?number' origin/main -- api/**                            # compose.ex, tiers.ex present (Elixir renders)
git grep -l  -niE 'field.?number' origin/main -- internal/**                       # pdrender/field_number.go present (Go renders)
bp task get pbw-stier-field-number -o json | python3 -c "import sys,json;[print(a['met'],a['criterion']) for a in json.load(sys.stdin)['doc']['content']['acceptance_criteria']]"
```

## Falsifier (proves the reason WRONG if it ever passes)
```
git grep -n field-number origin/main -- js/packages/react/src
```
Exit 0 = a React emitter appeared → reopen was wrong. Currently exit 1 → reason holds.

## Disposition
`bp task stage pbw-stier-field-number open` — lifecycle done->open, claim retained
(closed_by=stier-wave-lead, epoch 5). Not a fabrication-shape close: worker/epoch/digest
are all present — this is a genuine partial-done, one surface short of its own criterion.
