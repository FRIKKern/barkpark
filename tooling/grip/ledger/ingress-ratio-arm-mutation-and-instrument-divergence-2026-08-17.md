# Re-derivation — can a ratio arm catch the rem regression, and which CPL instrument is speaking? (2026-08-17)

Companion to `device-fixture-measures-h2-scale-and-ingress-ratio-2026-08-17.md`.
Device 5 re-cuts as a ratio assertion; this file proves the threshold by
MUTATION and names the two-instrument hazard behind any "66-72 CPL" arm.

## 1. What the arm must catch

`pe-w1-reader-editorial-typography` (closed 2026-08-12, PR #11626) converted every
role from `rem` to `em` precisely because applying the 18px body token with roles
left in `rem` collapses the ingress/body size ratio 1.28 → 1.14. Re-impose it:

```sh
# on each rendered fixture, in the page:
ing.style.fontSize = "1.28rem";   # root is 16px → 20.48px, the pre-#11626 size
```

Measured at 1280 (light), CPL ratio = ingress CPL / body CPL, seven fixtures:

| fixture | healthy own-text / canonical | REGRESSED own-text / canonical |
|---|---|---|
| design-probe | 0.759 / 0.783 | **0.853** / 0.880 |
| eight-minute-erasure | 0.765 / 0.783 | 0.860 / 0.880 |
| heggemsnes-act | **0.821** / 0.783 | 0.922 / 0.880 |
| hobby-hardening-capstone | 0.799 / 0.783 | 0.898 / 0.880 |
| mechanical-spacing-doctrine | 0.798 / 0.783 | 0.897 / 0.880 |
| paper-excellence-wave-2026-08-12 | 0.782 / 0.783 | 0.879 / 0.880 |
| portabledoc-showcase | 0.790 / 0.783 | 0.888 / 0.880 |

`root` font-size is 16px on every cell (so `1.28rem` = 20.48px, matching the
number the wave-1 task quotes).

## 2. The verdict on the threshold

A `<= 0.85` arm fed with **each element's own text** catches the regression on
7/7 — but the separation is 0.821 (worst healthy) to 0.853 (best regressed):
**0.032 wide**, with only 0.003 of margin on design-probe. The spread is pure
per-character sampling noise, so a new fixture, a re-worded ingress or a font
fallback can move a cell across the line in either direction.

The same arm fed a **canonical probe text on both sides** reads 0.783 healthy and
0.880 regressed on all seven, at 360, 768, 1280 and 1920 — zero spread, 0.05 of
margin on each side of a 0.83 threshold. Cut the arm in the canonical form.

## 3. There are TWO CPL instruments in this epic, and they disagree

* the rig / gate instrument — `shoot.mjs`, a per-element probe span in the
  element's own resolved font, median over `main p` with ≥120 chars. This is what
  `baselines/*.report.json` carries and what a gate would fire on.
* the wave-1 instrument — real line boxes via Range rects, collapsed by top, last
  ragged line excluded, quoted in `pe-w1-reader-editorial-typography`'s evidence.

Same papers, different answers (wave-1 at 1440 vs rig at 1280; the column is a
fixed 660/580 above ~1120px, so width is not the difference):

| paper | wave-1 line-box | rig probe |
|---|---|---|
| heggemsnes-act | 68.6 | 67.7 |
| hobby-hardening-capstone | 68.3 | 71.6 |
| mechanical-spacing-doctrine | 67.3 | 70.0 |
| paper-excellence-wave-2026-08-12 | 68.9 | 71.7 |
| portabledoc-showcase | 63.8 | 71.7 |

Up to **7.9 CPL apart**. Under the line-box instrument `portabledoc-showcase`
sits below a 66 floor (wave-1's own evidence says so); under the rig probe it is
comfortably in band. So `task-21b7dd42b946b64e`'s 66-72 tightening is
instrument-dependent, and the instrument it would run on has 0.1 CPL of ceiling
headroom (eight-minute-erasure 71.9).

```sh
bp task get pe-w1-reader-editorial-typography    # the line-box numbers, criterion 1
python3 -c "import json,glob;[print(json.load(open(f))['label'],[s['proseCpl'] for s in json.load(open(f))['shots'] if s['cell'].endswith('light__1280')]) for f in sorted(glob.glob('tooling/paper-excellence/rig/baselines/*.report.json'))]"
```
