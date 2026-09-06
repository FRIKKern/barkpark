# The 764/user-opened in-floor divergence was a hardcoded 80px addend

Dated 2026-09-06. Companion note to `spd-w8-followup-floor-formula-2026-09-06.json`
in this directory. Row: `spd-w8-followup-in-floor-formula-assumption`.

Read as a dated record, not as a live contract: the durable rule lives in the
instrument's own comments beside the derivation.

## Provenance

| | |
|---|---|
| served sha | `d10e8d9eb4778638ee511d12b7ddcc963c8a24ef` (requested via `--sha`, matched) |
| slot | `blue` |
| bracket | pre `11:19:34Z` / post `11:21:06Z`, `provenance_bracket_matched: true` |
| positive control | ran; the non-vacuity guard FIRED on the forced scrim |
| rows | 54 (9 widths x 3 faces x 2 states), 0 unsettled, 0 face substitutions |
| **drift warnings** | **0** (`warnings: []`) |

## The three warnings that are gone

Every committed run before this one carried exactly three, all at viewport 764
/ user-opened, one per face. They were arithmetic, not measurement.

The served floor is

```css
.editor-with-preview .editor-panel-main.bp-paper-body {
  container-type: inline-size; container-name: content; }
@container content (min-width: 720px) {
  .editor-panel .bp-paper-surface { min-inline-size: calc(55ch + 2 * var(--paper-gutter)); } }

.bp-paper-surface { --paper-gutter: 40px; max-width: 660px; padding: 56px var(--paper-gutter); }
@media (max-width: 767px) { .bp-paper-surface { --paper-gutter: 24px; padding: 48px var(--paper-gutter); } }
@media (max-width: 479px) { .bp-paper-surface { --paper-gutter: 16px; padding: 32px var(--paper-gutter); } }
```

The instrument hardcoded the addend as `80`, which is `2 * 40px` — right in the
widest gutter band only. In the 24px band the addend is 48, so subtracting 80
removed 32px too much, and the resulting in-floor ch came out low by exactly

    -32 / (55 * probe_px_per_ch)

= -5.27% georgia, -5.81% native, -6.34% source-serif-4. The addend is now READ
from the surface's computed `--paper-gutter`; those three cells land at
0.0089% / 0.1075% / 0.088%, the same residual every floor-bearing row has
carried since D83.

## Why only 764, and only user-opened

Two conditions must hold at once, and 764/user-opened is the only cell where
they do. `floor.container_content_box_px` and `floor.container_gate_open` are
recorded per row so this is read, not inferred.

1. **The 24px gutter** needs viewport <= 767px: 764, 700, 640, 500.
2. **An open container gate** needs the reading column's own content box at
   >= 720px.

| viewport | gutter | column box (default / user-opened) | gate open |
|---|---|---|---|
| 1440 | 40 | 836 / 836 | yes / yes |
| 1280 | 40 | 676 / 676 | no / no |
| 1024 | 40 | 679 / 680 | no / no |
| 900 | 40 | 815 / 856 | yes / yes |
| 800 | 40 | 715 / 756 | **no / yes** |
| 764 | **24** | 679 / **720** | **no / yes** |
| 700 | 24 | 615 / 656 | no / no |
| 640 | 24 | 555 / 596 | no / no |
| 500 | 24 | 459 / 500 | no / no |

Where the gate is closed the declaration never applies, `min-inline-size`
resolves to `0px`, `in_floor_px_per_ch` is null and **no divergence can be
computed at all** — that is why six of nine widths and the whole default state
stayed silent, not a tolerance that happened to hold. Where the gate is open at
40px of gutter (1440, 900, 800/user-opened), the hardcoded 80 was accidentally
exact. 764/user-opened is the single intersection: the narrow gutter with the
column at 720.0px, right on the gate.

The 800 and 764 default/user-opened split is the same fact from the other side:
opening the inspector at those widths widens the reading column (the docked
sidebar gives way to an overlay), which is what pushes the column over 720.

## What did NOT move

`probe_px_per_ch` is untouched, and every ch figure in the published visible
table is derived from the probe. No table cell changes. The 40px band's addend
is still 80 — computed now, not written down.
