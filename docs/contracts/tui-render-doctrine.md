<!-- doc-tier: agent | canonical-for: tui-render-doctrine | budget: 900tok -->
# TUI render doctrine — the detail ceiling

House law for every `internal/pdrender` data-viz block (heatmap, chart, stat,
gauge, and every block added after). One rule underneath all of it:

> **The datum lives in GEOMETRY. Color is REINFORCEMENT, never the encoding.**

Every ANSI-stripped render is a **complete artifact**: pipe it through
`ansi.Strip`, or read it on a NO_COLOR terminal, and no information is lost. If
stripping the color changes what the reader can know, the block is wrong.

## The machine-checkable law

For any block, at any width:

```
ansi.Strip(render at ANSI256) == ansi.Strip(render at TrueColor) == render at NoColor
```

Color escapes are the ONLY thing a higher profile may add. Geometry — glyphs,
alignment, labels, marginals — is byte-identical across all three profiles.
`assertStripComplete` (internal/pdrender/golden_profiles_test.go) is this law as
an executable check; every new block is held to it, at the golden widths.

## Encoding rules

- **Heat = dual-encode + quantile.** The shade-ladder glyph (`·░▒▓█`) carries the
  intensity at EVERY profile; the `GenHeatRamp` foreground is layered on top at
  `Profile>=ANSI256` (lipgloss degrades the hex below TrueColor; NoColor/ANSI16
  emit the glyph alone). Stripping the color still leaves the ladder. Bin by
  QUANTILE, not linear (one spike otherwise flattens months into a single tone).
  **Max 4 ramp levels** above zero — the eye cannot rank more in a grid.
- **Zero is the dim MIDDLE DOT `·`, never the lower-one-eighth block `▁`.** A
  zero cell must never be visually confusable with a low-but-present cell, and
  never blank (blank reads as "no data", not "zero").
- **Lines = box/braille curves, max 2 series.** More than two overplotted series
  in one cell-grid is unreadable; split or drop. Braille geometry renders at all
  profiles (it IS the datum); per-series color is the TrueColor-only reinforcement.
- **Braille / half-block only with a dual-encode fallback.** The high-resolution
  glyph may light at `Profile>=TrueColor`, but the same datum must remain legible
  in the stripped/NoColor render — never encode meaning in a glyph the floor
  profile can't reproduce.

## Hard readability line (never cross)

- **No color-only encoding.** If two cells differ only in color, the render fails
  the strip law.
- **No emoji in aligned grids** (variable cell width breaks column alignment).
- **No sixel / kitty graphics.** Terminal-native glyphs only.

## Dim is a foreground color, never Faint

Use `ctx.Theme.Dim` (a real foreground tone) for dimmed text — **never**
`lipgloss.Faint()` / SGR 2. The wasm reader's `applySGR` DROPS SGR 2, so a Faint
dim passes the Go goldens (which strip anyway) yet vanishes to full-bright in the
browser reader. `Theme.Dim` survives both paths.

## Two-knob profile plumbing (test gotcha)

A profile-aware render has TWO independent knobs that MUST agree, and their enums
run OPPOSITE directions:

| knob | type | order |
|---|---|---|
| `ctx.Profile` (pdrender.go) | `pdrender.Profile` | `NoColor=0 … TrueColor=3` (ascending) |
| `lipgloss.SetColorProfile` (process-global) | `termenv.Profile` | `TrueColor=0, ANSI256=1, ANSI=2, Ascii=3` (INVERTED) |

Setting only `ctx.Profile` leaves lipgloss at whatever the last test pinned —
truecolor escapes silently survive or vanish. A test that renders at a profile
must set BOTH, and must SAVE/RESTORE the global (it is process-wide). Use
`assertStripComplete`, which owns both knobs. Verified against
muesli/termenv v0.16.0 `profile.go`.

## Known gap

The truecolor heatmap ramp (`heatCell`, heatmap.go) currently paints a solid `█`
colored by intensity — a color-ONLY encoding that FAILS the strip law
(`strip(TrueColor)` loses every intensity distinction). It must be reworked to
dual-encode (shade-ladder glyph UNDER the truecolor foreground). This is a design
change to the flagship contribution heatmap (GitHub-solid vs Barkpark-dual-encode)
pending strategist sign-off — tracked, not silently changed here. Until then the
strip law is proven on the shade ramp + stat/stats + chart, not the truecolor grid.

## Code anchors
- internal/pdrender/golden_profiles_test.go — func assertStripComplete
- internal/pdrender/pdrender.go — Profile enum (NoColor..TrueColor)
- internal/pdrender/heatmap.go — func heatCell, func heatShadeGlyph
- internal/pdrender/chart.go — func chartUseTrueColor
