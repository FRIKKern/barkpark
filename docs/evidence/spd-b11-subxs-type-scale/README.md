<!-- doc-tier: human | canonical-for: spd-b11 sub-xs type rung density evidence | budget: 4000tok -->

# spd-b11 — the sub-xs chrome rung moved zero pixels

Three before/after pairs at **1440x1000** (deviceScaleFactor 2, so the PNGs are
2880x2000), recorded by `scripts/measurements/spd-b11-subxs-shot.mjs`. Raw run:
[`run.json`](run.json).

The row that filed spd-b11 says the reason a new rung was needed at all is that
force-mapping the desk's 102 sub-12px `font-size` literals onto the old floor
(`--text-xs: 12px`) would be *"a 1-3px visible density bump across roughly a
third of desk chrome that NO gate can see"*. Adding `type.chrome.2xs` (11px) and
`3xs` (10px) is supposed to make the sweep cost **nothing**. That is the claim no
gate in this repo can check, so it is the one shot here.

## What each pair is

The deployed guerrilla Studio serves `root.html.heex` blob
`f4f19129cb24d8b6cc613991805fc53b17e218e8` — **byte-identical** to the blob at
this branch's base commit `159ea0412a3772cb34b0f07910e9f3eb4e0a7ae2` (and still
identical at `14cc08e0c`, which the box redeployed to mid-run). So the served
page **is** the before state, with no rebuild and no sha ambiguity. The *after*
is this branch's diff replayed onto that live stylesheet, in the page: insert the
two emitted rungs after the `--text-xs` pair, then rewrite `font-size: 11px` ->
`var(--text-2xs)` and `font-size: 10px` -> `var(--text-3xs)`.

The substitution counts are asserted against what the branch actually changed —
**82 and 20**, across **both** of root.html.heex's `<style>` blocks (the sheet is
split around the `bp-paper-editor-shell.css` `<link>`; transforming only the
first is a trap this script fell into once, scoring 67/19). If the live sheet
were not this branch's base, the counts would not match and the run halts.

## The subject is asserted before the shutter

A pair of pictures of a surface that paints no sub-12px chrome approves nothing.
The first run of this script shot two byte-identical pairs of a
`Studio could not open this document.` error page. Every surface now declares a
floor on how many elements the browser must *resolve* to 11px / 10px, counted in
the page before the transform:

| surface | route / click | 11px | 10px |
|---|---|---|---|
| `1-media` | `/studio/media` | 70 | 5 |
| `2-papers-pane` | desk, click **Papers** | 8 | 101 |
| `3-tasks-pane` | desk, click **Tasks** | 8 | 201 |

Those same counts are re-taken *after* the transform and are **unchanged on all
three** (`resolved_sizes_unchanged: true`). That is the pixel-neutrality claim as
a number rather than as a picture: the 102 sites still compute to the sizes they
computed to before.

## The verdict

| surface | differing pixels (of 5,760,000) | max channel delta | where |
|---|---|---|---|
| `1-media` | 440 (0.008%) | 9 / 255 | 547x1238 at (1284, 59) — inside the thumbnail grid |
| `2-papers-pane` | 1,649 (0.029%) | 143 | 440x22 at (245, **1963**) |
| `3-tasks-pane` | 41,901 (0.727%) | 232 | 359x169 at (0, **1831**) |

**No density change.** Every difference with real contrast sits in the bottom
~170px of a 2000px frame — the live status footer (`CPU 100% · RAM 2.1/3.7 GB ·
disk 86% · load 5.99 · up 75d 9h`), which repaints between the two shutters on
its own. The `1-media` residue is the only difference above the footer and it
peaks at 9/255: antialiasing noise on re-decoded thumbnails, invisible to an eye
and three orders of magnitude too quiet to be a glyph. A 1px type change moves
baselines through the *whole* content column; nothing here does.

## Reproducing

```bash
# re-derive the pixel statistics from the committed PNGs — no browser, no token
node scripts/measurements/spd-b11-subxs-shot.mjs --out docs/evidence/spd-b11-subxs-type-scale --recompare

# re-shoot (needs the guerrilla admin token in ~/.config/barkpark/config.json)
BP_PLAYWRIGHT_FROM=<path to a playwright install> \
  node scripts/measurements/spd-b11-subxs-shot.mjs --out docs/evidence/spd-b11-subxs-type-scale
```

A re-shoot against a box whose `root.html.heex` has moved past this branch's base
will HALT on the 82/20 assertion rather than produce a misleading pair.
