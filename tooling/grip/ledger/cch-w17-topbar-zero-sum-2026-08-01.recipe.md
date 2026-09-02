<!-- doc-tier: cold | canonical-for: cch-w17-topbar-zero-sum-rederivation | budget: 6000tok -->

# Re-derivation recipe — CCH wave 17, `v1-topbar-zero-sum`

> HISTORICAL RECORD (2026-08-01) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Every number in the verifier's report is reproduced by these commands. Nothing below reads a
committed instrument's green as evidence: the topbar band (320–430) is BELOW `breakpoint-sweep.mjs`'s
Leg-B floor of 619, so every cell here is hand-driven and labelled as such.

## 0. Harness (once)

```
cd /Volumes/SATECHI/github/barkpark
D=$(mktemp -d) && git archive origin/main cloud/priv/static | tar -x -C $D
S=$D/cloud/priv/static
node $S/__preview__/serve.mjs --port 4301 &
sleep 2; curl -sf http://localhost:4301/ >/dev/null && echo SERVER_UP
```

Driver: `topbar.mjs` / `topbar2.mjs` / `topbar3.mjs` (scratchpad; CDP
`Emulation.setDeviceMetricsOverride`, one fresh target per cell, `Network.setCacheDisabled`).
Chrome 150.0.7871.187, node v22.22.0.

**Liveness sentinel, asserted BEFORE any measurement is recorded** (a NOCHIP cell is a race, not a
finding): `#billing-chip` exists AND `!hidden` AND has non-empty text AND at least one
`section.view` is unhidden. 272 of 272 cells passed; `NOCHIP: 0` in all three rounds.

## 1. The row is saturated — the arithmetic that decides the question

Per cell, from the base run: `chip.scrollWidth` + picker box-need + liveness chip + theme button +
3 gaps, against `.topbar-right`'s measured width and against the WHOLE `.topbar` content box.

Picker box-need is measured in-page, not assumed: an offscreen `<span>` inherits the picker's
computed font, every `BP_THEMES` option label is measured through it, the widest is taken, and the
picker's own padding + border + (when `appearance:auto`) a 16px native-chevron reserve is added.
Longest label is **"Evergreen"**, textW 58.28 → box-need **96.28** at `appearance: auto`.

| cell | width | sum of intrinsic needs | `.topbar-right` avail | `.topbar` inner (viewport − 2×14) | deficit vs the WHOLE bar |
|---|---|---|---|---|---|
| past-due | 320 | 341.58 | 221.06 | 292 | **49.58** |
| trial | 320 | 296.59 | 213.02 | 292 | **4.59** |
| past-due | 430 | 353.07 | 307.30 | 402 | −48.93 (fits) |

At 320 the four children plus gaps do not fit even if `.topbar-left` (measured 60.94 past-due /
68.98 trial) is confiscated entirely. **Reallocation cannot solve this; only demand reduction can.**

## 2. Candidate verdicts (20 cells each: 2 scenarios × 2 themes × 5 widths)

```
ONLY=base,a_ellipsis,b_railselect,c_phoneband,d_b_plus_c,e_all,f_chip_flexnone,g_b_plus_f node topbar.mjs
node topbar2.mjs   # h_picker_out, i_shortlabel, j_wrap, k_short_plus_wrap
node topbar3.mjs   # boundary 430/431/619/768 + picker flex:0 0 auto
```

- **(a) `text-overflow: ellipsis` on `#bp-theme-picker` — INERT.** All 20 cells byte-identical to
  base on every number. `text-overflow` does not apply to a `<select>`'s rendered value box in
  Chrome. Shipping it would be a fix whose only guard is a sentence.
- **(b) `.rail-select` treatment scoped to the picker — NET NEGATIVE.** `appearance:none` trades the
  16px chevron reserve for 26px right padding, so box-need RISES 96.28 → 98.23; the picker gains
  4px of client box and never clears; and the chip LOSES 3–4px in all 20 cells
  (past-due@320 clientWidth 85 → 81).
- **(c) phone-band chip tighten — partial.** chip need 121 → 105 (trial) and 168 → 147 (past-due);
  the picker clears in exactly 2 of 20 cells (trial@430).
- **(f) chip `flex:0 0 auto` + phone band — the theft, measured.** Chip clean in 20/20 (105/105,
  147/147) while the picker collapses to **clientWidth 20** at past-due@320 and the theme button to
  22. Fixing the chip destroys the picker.
- **(g) (b)+(f) — introduces a NEW page scroll:** past-due@320 `documentElement.scrollWidth`
  320 → **332**, both themes. No page-level guard on the trial cell would see it.
- **(j) phone-band WRAP — the only clean set.** See §3.

## 3. The remedy that clears all three

```css
@media (max-width: 430px) {
  .topbar { height: auto; min-height: 56px; flex-wrap: wrap; padding: 6px 12px; }
  .topbar-right { flex-wrap: wrap; justify-content: flex-end; gap: 6px; }
  .billing-chip { flex: 0 0 auto; }
}
```

20/20 cells: chip `scrollWidth == clientWidth` at FULL label (121/121 trial, 168/168 past-due),
picker clientWidth **99 ≥ 96.28**, liveness chip 24, theme button 48.8. Both themes.

Two things this recipe insists on:

1. **The trial cell still reads `docSW 413` at 320/360/375/390 — that is NOT the topbar.** It is the
   tier-grid page scroll D193/`cch-w16-s8` pays (413 − 320 = the 93px figure). The past-due cell,
   which has no tier grid, is `docSW == clientWidth` in all 10 of its wrap cells. Any criterion of
   the form "documentElement.scrollWidth == clientWidth in every cell" (which is
   `cch-w16-bl-trial-chip-truncated-on-every-phone`'s criterion 2, verbatim) is UNSATISFIABLE on the
   trial cell until s8 lands. Order or amend it; do not let a builder chase it.
2. **The cost is vertical.** `.topbar` height 56 → 84.5 at 360–430 and 116.5–118.5 at 320 (it
   becomes two rows, three at 320 on some cells). That is a design trade for Decide to ratify, not a
   free win.

**Boundary is clean.** At 431 / 619 / 768 the wrap run is byte-identical to base on every number
(barH 56, chip 121/110, picker 90, right 296.86 at 431) — the block cannot leak upward into s6's
tablet bands. Base also reads chip `168/168` and `121/121` clean at 619 and 768, so the phone band
and s6's `max-width: 768px` blocks are disjoint as filed.

## 4. Baseline cost, by the D158 recipe (not arithmetic)

```
cp app.css.with-wrap $S/cloud/priv/static/app.css
printf '# scratch sentinel\n1\n' > $S/__preview__/cssom-heads.baseline
node __preview__/cssom-parity.mjs --port 4399 ; echo "EXIT=$?"
```

Pristine origin/main bytes → `authored rule heads 1253`, MISSES 0, exit **1**.
With the wrap block → `authored rule heads 1256`, CSSOM style rules 1256, flattened selectors
1218/1218, MISSES 0, exit **1**, and the tool NAMES the value in its own failure text:
`!! BASELINE MISMATCH: 1256 authored rule heads, sidecar baseline is 1 (+1255)`.

So the wrap is **+3 authored heads, 1253 → 1256**, an unrecorded ADD (MISSES 0), never a parity
defect. Exit codes were read from `$?` on the bare command — never through a `| tail` chain, which
reports the pager's success and not the tool's.

`grep -cE '^[0-9]+$'` on the written baseline returns **1**.

## 5. What this recipe does NOT establish

- Nothing about 721. The 721 cell was not driven here; s6's own band claims stand on their own runs.
- Nothing about keyboard/AX consequences of a two-row topbar, or about `.content` offset under the
  taller bar. Both are open questions the wrap creates.
- The digest's exact "picker `flex:0 0 auto` shrinks the past-due chip 72.5 → 43.2" figures were not
  reproduced at 320; the MECHANISM is confirmed at 430/431 (past-due chip clientWidth 134 → 119,
  liveness 22.16 → 21.36, button 42.63 → 39.95). Quote the mechanism, re-derive the figures.
