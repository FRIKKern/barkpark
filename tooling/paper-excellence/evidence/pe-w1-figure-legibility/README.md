<!-- doc-tier: human | evidence archive for bp task pe-w1-figure-legibility -->

# pe-w1-figure-legibility — measured evidence

Hermetic rig: the real emitter (`DataViz.chart_html/1`) + the real compiled
stylesheet (`Render.Stylesheet.css/0`) rendered to a standalone page, measured
in Chrome via CDP at emulated viewports with `devicePixelRatio 1`. The
"before" state is a byte-identical revert layer (min-width 0, flat 0.08 region
opacity, container-bound mermaid svg, text-anchor middle) — so before/after
compare the exact shipped declarations.

## Effective paint size at a 360px viewport (dpr 1)

| figure text                    | before  | after   |
|--------------------------------|---------|---------|
| chart tick (11px viewBox)      | 5.09px  | 11.0px  |
| chart annotation (10px viewBox)| 4.63px  | 10.0px  |
| mermaid sequence label (16px)  | 3.60px  | 16.0px  |

At 320px: chart tick 11.0px, annotation 10.0px, mermaid 16.0px. The page body
never scrolls horizontally (`document.scrollWidth <= innerWidth` at 360 and
320); the figures scroll inside their own containers (`.bp-chart__scroll`,
`pre.mermaid` — both `scrollWidth > clientWidth` at narrow widths).

## Point annotation clamp (viewBox 0..640)

- last index, label "floor 19": before `text-anchor=middle` bbox right
  **654.1** (clips past 640); after `text-anchor=end` bbox right **630.0**.
- index 0, label "start here": bbox left **15.9** — inside the viewBox with
  anchor middle (the emitter flips to `start` only when the estimated box
  would cross the left edge).

## Region tones (info vs danger), both themes

- `region-tones-before-light.png` / `region-tones-before-dark.png` — flat
  opacity 0.08: the two washes are near-indistinguishable.
- `region-tones-after-light.png` / `region-tones-after-dark.png` — opacity
  ladder (info/ok 0.10, warn 0.14, danger 0.18): the info wash reads cool,
  the danger wash reads warm, in light and dark.
