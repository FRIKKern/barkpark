# RULING — the two unwrapped recipe rows are RESCUED, not declined

Builder, truth-grip wave 11, 2026-09-02, task `tgw11-bl-unwrapped-recipe-rows-unread`.
Store read at HEAD `bae26042`.

## What they are

`grip-20260723T000000Z-v-premise-smoke-canonical-lines.json` and
`grip-20260723T000100Z-v-premise-smoke-block-count.json` each hold ONE recipe's
fields at top level — `deps, derived_level, observed_at, quantity, rerun,
subject` — with no wrapper and no `run_id`. That is the complete `RECIPE_FIELDS`
set and nothing else. They are recipes, not notes: of the 15 files the fold
classes NOT-A-RUN today, these two are the only ones whose key set is a subset
of `RECIPE_FIELDS`; the other 13 are foreign documents keyed on `facts`,
`claims`, `census_*`, `numbers` and the like.

## The ruling: RESCUE through the real write path

Both `rerun` commands were re-run at HEAD and both still execute and answer
(1141 and 8). Neither stores a value — the `quantity` field is a PHRASE naming
which property is re-derived, which is what the schema asks for, so
`VALUE-STORED` never applies. `prescreen` admits both ("within the host bound,
allowlisted head and sub-verb, no write shape"), so the write path can express
this repair and there is no reason to decline.

The rescue is `node tooling/grip/ledger.mjs write <facts>` — the REAL write
path, so every row crossed `admitRecipe` with `now` and the screen armed, and
the resulting file is write-path ATTESTED (its name reproduces the digest of its
own bytes). It produced `grip-20260902T001307Z-67bb79c201ce8414.json`. Nothing
was edited, moved, renamed, deleted or gitignored; the two originals stay
exactly where they are, and stay NOT-A-RUN.

## What the fold does NOT do, stated plainly

The unreadable count does NOT drop by two. It cannot: D118 forbids removing the
originals, and they are still the same unwrapped documents the fold correctly
declines to guess a chain of custody for. `not_a_run` stays 15 and `unreadable`
stays 507. What moves is the READ side: runs 78 → 79, files 93 → 94, owned 50 →
51, attested 26 → 27, rows 354 → 356, subjects 302 → 303. The evidence became
readable by ADDITION, which is the only way an append-only commons can heal.

## Two things the filing had wrong

1. **Half of it was already readable.** `grip-20260723T000000Z-v-fence-controlflow.json`
   — a properly wrapped run file written by the same author at the same instant —
   already carries the canonical-lines `rerun` VERBATIM, under the same folded
   key. Only its stored `quantity` string differs, and the fold re-derives that
   half of the key anyway. So the fold HAD read that recipe; what it had never
   read was the block-count `grep -c` variant, which is genuinely absent from
   every wrapped file (a `grep -nE 'const [A-Z_]+_BLOCK ='` listing exists, which
   is a different quantity).
2. **The class grew.** The filing counted TEN files without `recipes[]`, eight of
   them foreign. Today it is FIFTEEN, thirteen foreign. The two recipe-shaped
   ones are unchanged, so the ruling stands — but a census in a shared commons
   is a measurement with a timestamp on it.

## The regression this rescue exposed, and the fix

Re-recording an existing recipe writes a row whose `rerun` is byte-identical to
one already stored under that key, with a fresher `observed_at` and nothing else
changed. That is exactly what `observed_at` means ("when this recipe last ran"),
and it is exactly what D118's append-only repair must produce. It reddened
`census.test.mjs`'s ledger fold test, which asserted
`skippedRivals === rows - subjects`.

That identity was never a property of the reader. `loadLedgerRecipes` counts
DISTINCT rerun STRINGS past the first per key; `rows - subjects` counts ROWS past
the first. They agree only while no two rows under one key share a command — an
accident of the store that had held until now, and one that the prescribed repair
is guaranteed to break. The assertion is re-pinned against the `allRivals` load
(`all.commands.length - source.commands.length`), which is the count of exactly
what the deduping load drops, and `rows - subjects` is kept as an upper bound with
the gap NAMED. Non-vacuity proven by mutation: a `+1` drift in the accumulator
reds it.

## Reruns

    git show origin/main:.claude/workflows/bp-epic-cycle.workflow.js | wc -l
    git show origin/main:.claude/workflows/bp-epic-cycle.workflow.js | grep -c '_BLOCK = `'
    node tooling/grip/ledger.mjs fold                    # stderr banner carries the shape census
    node --test tooling/grip/test/*.test.mjs             # 811 tests, 810 pass, 0 fail, 1 skipped
    node tooling/grip/ledger.mjs --selftest              # 19/19 controls fired

## Still open

`ledger.mjs`'s read-path header still states the OLD ruling ("They stay
NOT-A-RUN … The append-only-legal repair is to RE-RECORD those two rows through
`writeLedgerRun` … which is filed as `tgw11-bl-unwrapped-recipe-rows-unread`").
The repair has now happened, so that paragraph wants its last two sentences
replaced with a pointer to this note and the attested run file. It is NOT edited
here: PR #14925 is open against the same block and a second writer there buys a
conflict for a comment.
