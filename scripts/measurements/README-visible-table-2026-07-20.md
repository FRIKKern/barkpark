<!-- doc-tier: agent | canonical-for: spd-visible-table-2026-07-20 provenance | budget: 3000tok -->

# The July-20 visible table is HISTORY, not a baseline

`spd-visible-table-2026-07-20.json` and its twin `spd-visible-table-verify-2026-07-20.json`
were both measured on deployed `served_sha`
`65541e2d43e7ea116c6d49e0ac0b1e0109c93a8f`. Each now carries the same verdict
in-file under the top-level `historical_status` key. This file is the prose
version of it.

## Why they are not comparands

Two product generations shipped after the measured build:

| Generation | Merge | Ancestor of `65541e2d4`? |
|---|---|---|
| Tier-2 ladder (#4922) | `4074d1986` | NO |
| Tier-3 return grammar (#5014) | `37740a5e9ce4e416a31b87f3afdb0ef6eb085aac` | NO |

Reproduce either verdict directly — a non-zero exit is the NO:

```
git merge-base --is-ancestor 4074d1986 65541e2d43e7ea116c6d49e0ac0b1e0109c93a8f
git merge-base --is-ancestor 37740a5e9 65541e2d43e7ea116c6d49e0ac0b1e0109c93a8f
```

The instrument moved too: these rows predate the per-row non-emptiness summary
the current sweep emits, so a header-field diff against any fresh run differs on
SCHEMA before it differs on geometry.

The consequence is the trap this note exists to close: a fresh run row-compared
to either July-20 file reports DIVERGENT **by construction**, and that verdict
means nothing. A determinism claim must be run-1 against run-2 of the SAME
build; neither of these can be either leg for any build but their own.

The distance from the measured sha to `main` grows daily. Never quote a frozen
number — compute it:

```
git rev-list --count 65541e2d43e7ea116c6d49e0ac0b1e0109c93a8f..origin/main
```

## What they still prove

The BEFORE picture, and it is load-bearing. At viewport 1024 / user-opened,
BOTH files record, on all three faces: `panel_px` 720, `scrim.renders` true,
`scrim_alpha` 0.55, `dimmed_content_px` 378.958,
`panes.visible_pane_widths_px` `[44, 260]`. That is a REAL painted scrim at
the standard bucket on the measured build — the state the Tier-2 ladder is
claimed to have removed. Cite these files for that, and for nothing else.

## The comparand baseline

`spd-bracketed-deployed-bracket-2026-07-22.json` — raw runs
`spd-bracketed-deployed-run1-2026-07-22.json` and
`spd-bracketed-deployed-run2-2026-07-22.json`.

Measured on deployed `served_sha`
`bdd7dac40dfbc3e1c91e252e202163480031a730`, which HAS both merges above as
ancestors:

```
git merge-base --is-ancestor 4074d1986 bdd7dac40dfbc3e1c91e252e202163480031a730   # exit 0
git merge-base --is-ancestor 37740a5e9 bdd7dac40dfbc3e1c91e252e202163480031a730   # exit 0
```

At the same cell (viewport 1024 / user-opened) both raw runs record, on all
three faces: `panel_px` 980, `surface_border_box_px` 680, `content_px` 600,
`dimmed_content_px` 0, `panes.visible_pane_widths_px` `[44]`. The bracket file
states the relationship itself, under
`highest_information_bracket_1024_user_opened` (720 -> 980, alpha 0.55 -> 0)
and under `registered_prediction.why_not_the_baselines`, which already rejects
the July-20 pair by name.

`spd-w8-followup-floor-formula-2026-09-06.json` (deployed `served_sha`
`d10e8d9eb4778638ee511d12b7ddcc963c8a24ef`) is also post-ladder and
post-return-grammar, but it is a narrower follow-up sweep, not the paired
bracket the comparand role needs. Use the July-22 bracket.
