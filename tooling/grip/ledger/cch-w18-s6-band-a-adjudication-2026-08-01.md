# cch-w16-s6 band-A adjudication — re-derivation recipes (wave 18 VERIFY, 2026-08-01)

All measurements taken on a scratchpad extraction of `origin/main` at `b266a1a5e`
(`git archive origin/main cloud | tar -x -C $D`), Chrome/150.0.7871.187, node v22.22.0.
Chip = `#billing-chip`; "clean" = `scrollWidth <= clientWidth`.

## R0 — reproduce the tree and the guard leg

    D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x -C $D && cd $D
    export CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    OVERFLOW_GUARD_PORT=4386 node cloud/priv/static/__preview__/overflow-guard.mjs --defect GR108-tablet-topbar-overflow; echo rc=$?

`rc=0`. NOTE: the single `--defect` flag WORKS on merged main — one leg ran, exit 0.
Band A prints with a `~` marker and the row line reads "13 of 17 tablet widths — 4 band-A
cells cut within the 9px residual (cch-w17-bl-band-a-shell-fold-cliff), NOT clean".
So the guard PASSES while s6's criterion 1 FAILS, by two different tolerances:

    grep -n "CHIP_BAND_A\|const cut = " cloud/priv/static/__preview__/overflow-guard.mjs
    :303  const CHIP_BAND_A = new Set([721, 725, 730, 735]);
    :304  const CHIP_BAND_A_MAX_SHORTFALL = 9;
    :630  const cut = chip.sw > chip.cw + 1;

Band A (721-735) is a DECLARED, CAPPED, ATTRIBUTED residual — exemplary, prints `~`.
The `+ 1` at :630 is neither. It applies to **every** width in `CHIP_WIDTHS`, is named
nowhere, and prints **no marker at all**: 740/dark reads `168/167` in the row while the
summary line calls the chip "whole across 13 of 17". Pre-fix 805/dark was the same shape.
The file's own comment at :644 says a green sentence beside its own red "does not get to
do that again" — it still does, one pixel quieter. s6's criterion 1 is a bare `<=`, i.e.
STRICTER than the guard meant to enforce it, so criterion 1 stays unmet at 740/dark even
after a perfect band-A fix. Any amendment must either cut to band B or declare the ±1.

## R1 — band B is 48/48 clean; band A is 18/68 cut

Same run. Band B {741,750,768,769,775,780,785,800,805,810,820,830} reads `168/168` in all
four (scenario x theme) rows => 12 widths x 4 = 48/48.
Cut cells across s6's full 17-width set: 721/725/730/735 in all four rows (16) plus
740/dark in both scenarios (2) = **18 of 68**.

## R2 — the cause is the 720 shell fold, NOT GR116's tighten

Probe script (scratchpad copy of the guard's bring-up; reads computed style + rects):

    PROBE_PORT=4401 PROBE_WIDTHS=719,720,721,722,725,730,735,740,741 \
      node cloud/priv/static/__preview__/probe-s6.mjs

    719  chip=168/168  pad=14px/14px gap=10px  topbarW=719 sidebarW=719 sidebarH=300 shellDir=column
    720  chip=168/168  pad=14px/14px gap=10px  topbarW=720 sidebarW=720 sidebarH=300 shellDir=column
    721  chip=168/160! pad=14px/14px gap=10px  topbarW=489 sidebarW=232 sidebarH=900 shellDir=row

`.topbar` computed padding and column-gap are **IDENTICAL** across the boundary
(14px/14px, 10px) — GR116's tighten is already in force at 721. What changes is
`.app-shell` flex-direction column->row: sidebar 720x300 -> 232x900, topbar 720 -> 489.
A **231px** cliff. Page scroll is 0 at every width in the sweep.

## R3 — the 1px dark cells are REAL sub-pixel geometry, and the lever is the theme toggle

    PROBE_PORT=4417 PROBE_WIDTHS=721,740 PROBE_SCENS=billing-past-due node …probe-s6.mjs

    740/light  chip=168/168  chipRect=169.781  theme-toggle:48.80
    740/dark   chip=168/167! chipRect=169.344  theme-toggle:50.78

Border is 1px/1px both themes, so content = rect - 2. Light 167.78 -> clientWidth 168;
dark 167.34 -> 167. The dark theme's `theme-toggle` is **+1.98px wider**, which squeezes
`#billing-chip` by 0.44px. Not rasterisation:

    OVERFLOW_GUARD_CLASSIC_SCROLLBARS=1 PROBE_PORT=4402 PROBE_WIDTHS=719,…,768 node …probe-s6.mjs

reproduces every cell identically. CAVEAT, stated because it weakens the proof:
`billing-past-due` does not vertically overflow at height 900 (`scrollHeight 900 ==
clientHeight 900`), so classic-vs-hidden scrollbars is inert there. It is NOT inert for
`overview-past-due` (`scrollHeight 1147 > 900`), and that scenario's cells are identical too.

## R4 — 4px clears band A; the token-legal 8px does NOT; `calc(var(--space-2)/2)` does

Three variants appended to `app.css` AFTER the `@media (max-width: 830px)` block (:3910):

    V4   .topbar { padding: 0 8px; gap: 4px }                                   (filed shape proof)
    V8   .topbar { padding: 0 8px; column-gap: 8px }                            (--space-2 = 8px, app.css:342)
    V4c  .topbar { padding: 0 var(--space-2); gap: calc(var(--space-2) / 2) }   (fully token-derived)

    for v in v4 v8 v4c; do (cd $v && PROBE_PORT=441x PROBE_WIDTHS=721,725,730,735,740,741 node …probe-s6.mjs); done

    V4   band A cut cells: 2  (721/dark 168/167 in both scenarios) — light 100% clean
    V8   band A cut cells: 6  (721/light 166, 721/dark 165, 725/dark 167, x2 scenarios)
    V4c  band A cut cells: 2  — cell-for-cell IDENTICAL to V4, computed gap resolves to 4px

So `--space-2` at 8px is **3x worse** and 3px worse at the worst cell. But
`calc(var(--space-2) / 2)` is token-DERIVED, needs no new token, and reproduces the 4px
geometry exactly => `cch-w17-bl-band-a-shell-fold-cliff` criterion 4 is SATISFIABLE.
V4c 721/dark residue is `chipRect=168.922` -> content 166.92 vs scrollWidth 168 = a real
**1.08px** shortfall (again the dark theme-toggle, 50.69 vs 48.80).

## R5 — the head cost is +1 for every variant, and parity CANNOT see the placement trap

    (cd v4  && node cloud/priv/static/__preview__/cssom-parity.mjs); echo rc=$?   # 1253 (baseline 1252), MISSES 0, rc=1
    (cd v4c && …)                                                                 # identical
    (cd v4before && …)                                                            # identical

`v4before` = the SAME V4c block authored at :3911, one line BEFORE the 830 block:

    PROBE_PORT=4415 PROBE_WIDTHS=721,730,740 node …probe-s6.mjs
    721 chip=168/160! pad=14px/14px gap=10px      # cell-for-cell identical to untouched main

At equal (0,0,1,0) specificity the later `@media (max-width: 830px) { .topbar { padding: 0
14px; gap: 10px } }` wins inside 721-740. The block is a **measured no-op** — and
cssom-parity still reports +1 head with MISSES 0. A builder can ship a band-A "fix" that
passes parity, bumps the baseline, and changes nothing. Same class as the 430/`:3915`
trap the wave already anchored, now proven at the band-A site by driving.
