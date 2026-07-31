# Wave 29 — charter premise smoke: re-derivation recipes

Pinned tree: `origin/main` = `0f28d541e2b8b1412c7f4ee373950443dca7f49c`.
Charter: `.claude/workflows/bp-pds-charter.md`, 6489 lines.

## R1 — the negative: no charter text names hzResDone as wave 29's spine

    git show origin/main:.claude/workflows/bp-pds-charter.md | grep -ni 'wave.29\|wave-29\|w29'

Expect EXACTLY one hit: `6337:` (PDS-D392's anchor-retirement clause). Any second hit means the
charter moved and the phantom-citation finding must be re-derived.

## R2 — every "cut" of hzResDone, case-insensitive

    git show origin/main:.claude/workflows/bp-pds-charter.md | grep -ni 'stays cut\|is cut from\|CUT regardless'

Expect 6 hits: 5418 (D357, unrelated), 5721 (D367), 5815 (wave 27 spine), 6092 (D384a),
6141 (wave 27 plan), 6487 (wave 28 plan). Note the case-SENSITIVE `grep -n 'stays cut'` misses
6092 ("stays CUT regardless") — do not use it alone.

## R3 — the authorizing sentence

    git show origin/main:.claude/workflows/bp-pds-charter.md | grep -n 'wave-sized slice'

Expect 5613 (wave 26 review, "WHAT THE NEXT WAVE SHOULD TAKE" item 4) and 5730 (PDS-D367's own
closing clause). 5730 is the authorization; 5613 is the standing recommendation neither wave 27
nor wave 28 took.

## R4 — D395 is wave-28-scoped by its SECTION, not by its sentence

    git show origin/main:.claude/workflows/bp-pds-charter.md | grep -n '^## '
    git show origin/main:.claude/workflows/bp-pds-charter.md | awk 'NR>6215 && /^## /{print NR}'

Second command must print NOTHING: D395 (:6389) sits inside `## Wave 28 … DECIDED` (:6215), the
final top-level section. Its headline carries no wave qualifier; its scope comes from the header.

## R5 — the population

    git grep -n 'hzResDone(' origin/main -- internal/cli | grep -v _test.go | grep -vc 'func hzResDone'

Expect `50`.

## R6 — the registry row's real coordinates

    git show origin/main:internal/cli/success_claim_registry_test.go | grep -n 'hzResDone'

Expect `233` (row Name), `236` (the `attach`/`volume` probe with `nil` extra), `446`
(`requiredEnrollments` pin). The ledger row `pds-w25-backlog-hzresdone-receipt` cites `:198` —
STALE; D367/D384 imply :232-239.
