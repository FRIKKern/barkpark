# The studio-desk matrix coverage boundary

**Owner row:** `spd-b30-instrument-coverage-one-document-one-path` — the
canonical coverage owner after the ring-20 duplicate fold (it absorbed
`spd-w5-scrollbar-platform-caveat`, including `spd-b43`'s per-width evidence,
and `spd-b36-cross-browser-surface-measure-coverage`).

Dated 2026-09-22. This file is the companion; **the boundary itself is
`COVERAGE_BOUNDARY` in `scripts/studio-desk-measure.mjs`**, it rides in every
matrix that instrument writes as `run.coverage_boundary`, and it is printed
under every human table. That is deliberate and it is the whole point of the
row: *a boundary stated somewhere else is a boundary nobody reads.* A reader
with the JSON in front of them can now learn what it does not cover without
finding this file.

| where the boundary lives | what it is |
|---|---|
| `COVERAGE_BOUNDARY` in `scripts/studio-desk-measure.mjs` | the live object — one text, two renderings |
| `run.coverage_boundary` in every matrix JSON | the same object, travelling with the numbers |
| the human table footer | the same object, rendered verbatim per axis |
| `scripts/studio-desk-coverage-boundary.test.mjs` | asserts it rides in the run, drops no axis, and that its **motion ruling matches the committed probe output** |
| this file | the derivation, the evidence, and what was refused |

## What the matrix covers

One document, reached by one navigation path, in one browser engine, on one
platform, in one motion regime. Nine widths x three faces x two inspector
states = 54 rows. Everything outside that is **UNMEASURED, which is not the
same as working.**

## Platform / scrollbar — an analytic bound, with its control

Every committed matrix reports `scrollbar_width_px: 0` in all 54 rows, because
macOS paints overlay scrollbars. Windows and Linux/GTK paint a classic ~15px
one, which removes that much **layout viewport** at every width. Nobody in this
epic has such a host, so the honest options were a measurement there or a bound
here. This is the bound: `scripts/studio-desk-scrollbar-bound.mjs`, output
committed at `spd-b30-classic-scrollbar-bound-2026-09-22.json`.

**The model may not publish until it runs backwards.** At the matrix's own
scrollbar width it must reproduce every measured `surface_border_box_px`,
`content_px` and `container_gate_open`, or it refuses and names the misses. It
reproduces all 54 rows. And a control that cannot fire is not a control, so the
test also pushes a deliberately wrong model — the `@container` gate ignored,
the mistake a careful reader of the CSS still makes — through the same guard
and asserts the refusal.

Against `spd-b42-deployed-default-state-2026-09-22.json` (served `b8e1f8c92`,
bracket matched), at 15px:

| quantity | result |
|---|---|
| per-row `content_px` delta | **0px in 35 rows**, **-15px in 18**, **-27.632px in 1** |
| per-row `content_ch` delta | the px delta over that row's **own** probe: -1.5ch native, -1.358ch georgia, -1.636ch source-serif-4 |
| `@container` gate flips | **6 rows**, at exactly two cells: `1024/user-opened` and `764/user-opened` — both sit on **720.0px** |
| floor-binding rows | **6 -> 5**. `1024/user-opened/georgia` stops binding; cross-checked against the instrument's own forced-to-0px bind experiment, not against this model |
| 55ch verdict flips | **3, all true -> false**: `640/default/source-serif-4` (55.278 -> 53.642), `1024/user-opened/georgia` (55.005 -> 52.503), `700/user-opened/georgia` (55.038 -> 53.68) |
| gate reachability, user-opened | **764px -> 779px of CSS viewport, exactly** |

The 0px rows are the ones where the surface is capped by `max-width: 660px` or
held by its `min-inline-size` floor: a narrower column changes neither. The
-15px rows are the ones where the column itself is the binding constraint. The
single -27.632px row is the one where losing 15px **closes the gate**, dropping
the surface off a 687.625px floor back onto the 660px cap.

**The reachability shift is derived, not quoted.** Within a width bucket the
reading column tracks the layout viewport 1:1 — readable straight off the
matrix (user-opened: 800->756, 764->720, 700->656, 640->596, each a 1:1 step).
`764/user-opened` has a column content box of **720.0px against a 720px gate,
i.e. zero headroom**, so the shift is exact rather than a bound. The `default`
state has no swept width on the gate, so its shift is reported as an **upper
bound and says so.**

### What the bound does NOT cover, stated beside it

- **The `@media` gutter bands.** `--paper-gutter` switches at 767px and 479px of
  *layout* viewport, so a classic bar moves those edges to **782px and 494px of
  CSS viewport**. None of the nine swept widths lands in either 15px window, so
  the bound holds the gutter fixed — correct at these nine widths and silent
  about the two windows nobody has sampled.
- **The width-bucket stamp.** `bucket(window.innerWidth)` in `root.html.heex`
  reads a scrollbar-**inclusive** width; `@media` and `@container` read a
  scrollbar-**exclusive** one. On a classic platform the JS bucket and the CSS
  band therefore disagree by the scrollbar width near every edge (640/1024/1280
  for the bucket, 767/479 for the gutter). Only the CSS side is modelled.
- Any scrollbar width other than the one passed in, and anything a classic
  platform changes that is not the layout viewport.

## Engine — Chromium only, and it says so

`browser_policy` / `browser_version` name the exact build in every run. **Gecko
and WebKit measure nothing here and no claim in this matrix extends to them.**
`ch` is a font measurement, and the three engines differ in font fallback, in
sub-pixel layout rounding, and in whether a scrollbar is classic by default —
so a 55ch verdict is a Chromium verdict.

This is the criterion's second branch taken deliberately. A second engine was
not refused on principle: no Gecko or WebKit host is available to this epic
(the playwright cache here holds `chromium-1217` and
`chromium_headless_shell-1217` and nothing else). An explicit "this is
Chromium-only and says nothing about other engines" is worth more than a second
engine measured badly, and a test refuses any softening of that sentence into
"other engines should behave the same".

## Surface — papers, and only papers

`.bp-paper-surface` inside `.editor-panel`, plus the desk panes the drill passes
through. **Classic non-paper documents (sheets, tickets, quiz, ONIX records)
are not measured** — they render their own editors and carry no
`.bp-paper-surface`, and the instrument asserts selector match counts before
trusting any number, so it would refuse rather than report a confident zero.
**Additional `.editor-panel` roots** (the sheet grid and the graph view both
mount inside one) are likewise unmeasured. Anything this matrix says about
reading width applies to papers and to nothing else.

## Path — one, and the alternative was measured and retired

Root desk -> Papers pane -> a named row, by real clicks. A cold load straight to
the document URL is **not** swept, and that is a measured equivalence rather
than an untested assumption: `entry_state` was an axis, measured twice at nine
widths and three faces, and agreed in **54 of 54 cells both times** (D110),
which is why it was replaced by `inspector_state`.

## Motion — the ruling, with source AND computed-style evidence

The criterion asks for a measurement, not a judgement, so both halves were
taken.

**Source.** `root.html.heex` declares, on the desk: `transition: width
var(--dur-1) ease, min-width …, max-width …` on `.pane-column`; the same box
transition plus `background` on `.pane-column--collapsed`; `animation:
bp-pane-strip-in var(--dur-1) ease-out both` on `.pane-column--collapsed > *`;
and a `@media (prefers-reduced-motion: reduce)` block that nulls the box
transition down to `background` and the animation to `none`.

**Computed style, live.** `scripts/studio-desk-motion-probe.mjs` against
deployed guerrilla at **`f703de669`** (HTTPS `/status.json` bracket matched;
output `spd-b30-desk-motion-2026-09-22.json`), two arms with
`prefers-reduced-motion` emulated by the browser, two surfaces (bare desk, and
a drilled paper), 1280px:

| selector | no-preference | reduce |
|---|---|---|
| `.pane-column` | `0.15s` on width/min-width/max-width | `0.15s` on **background only** |
| `.pane-column--collapsed > *` | `animation: bp-pane-strip-in 0.15s` | `animation: none 0s` |
| `.pane-item` | `0.15s` background, border-color | unchanged |
| **`.editor-panel`** | **`0s`** | **`0s`** |
| **`.editor-panel-main.bp-paper-body`** | **`0s`** | **`0s`** |
| **`.bp-paper-surface`** | **`0s`** | **`0s`** |

**Ruling: a live transition EXISTS** — so reduced-motion coverage was warranted
and has been added, which is the branch the criterion points to. **And every
element the matrix actually measures reports `transition-duration: 0s` and
`animation-name: none` in BOTH regimes**, with a non-zero match count, so the
matrix is motion-regime-independent *by measurement rather than by assumption*.
A matrix swept under `reduce` has therefore not been produced; if a transition
is ever added to the surface or the reading column that ruling expires, and the
probe is how to re-take it. `studio-desk-coverage-boundary.test.mjs` reds if
the committed probe ever stops supporting the sentence.

**Two guards, because a zero is the easy answer to fake.** The *emulation
control* requires the reduce arm to report `matchMedia(...).matches === true`
and the no-preference arm `false` — without it the two arms could be the same
arm and "reduced motion changes nothing" would be free. The *non-vacuity guard*
requires at least one selector to match an element **and** report a non-zero
duration; a probe that matched nothing prints "0s everywhere" in exactly the
same shape as a desk with no motion.

**That indistinguishability had already produced a false artefact.** The
`.pane-column` rule in `root.html.heex` carried, in the present tense, directly
above the declaration that falsifies it: *"(measured live: transitionDuration 0s
on every desk element)"*. It described the desk before that line existed. It is
now corrected in place and points at the probe.

## What was refused, and why

- **A second browser engine.** No Gecko or WebKit host. Recorded as a
  Chromium-only claim instead of manufactured.
- **A live 54-row re-sweep of the matrix.** `studio-desk-measure.mjs` reads its
  provenance over `ssh root@157.180.90.121` and dies without it (D47). That key
  is not held by this session — `Permission denied (publickey,password)` — so a
  new matrix could not be produced, and the bound was derived against the
  committed `spd-b42` run instead. The motion probe brackets over HTTPS
  `/status.json` precisely so a motion reading is not lost to the same refusal,
  and it **names the weaker source** in `provenance.method` rather than dressing
  it up as the ssh read: `/status.json` reports the commit the app process
  believes it runs and cannot see the blue/green slot.

## Expiry conditions

The boundary carries `what_would_change_this`, and the test requires it to be
non-empty: a Gecko or WebKit host reaching the epic; a classic-scrollbar host
(the bound becomes checkable rather than derived); a transition appearing on
`.bp-paper-surface` or the reading column; or a non-paper editor gaining a
`.bp-paper-surface`, which would silently widen what this matrix claims.
