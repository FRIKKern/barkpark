# Re-derivation — h2 display scale + per-role CPL across the seven rig fixtures (2026-08-17)

Paper Excellence wave 2, verifier lane `device-fixture-measures`. Two questions:
(a) does `.bp-paper-surface h2` carry a DISPLAY type scale or only the 2px rule
(device 3's third leg), and (b) is the ingress→prose CPL ratio stable enough
across the committed panel to be cut as a gate arm (device 5's re-cut).

Everything below is hermetic: no server, no database, no network.

## 0. Render the seven committed fixtures

```sh
cd api
for f in ../tooling/paper-excellence/rig/fixtures/*.json; do
  MIX_ENV=test mix run --no-start ../tooling/paper-excellence/rig/render.exs \
    "$f" "/tmp/rig/$(basename "$f" .json).html"
done
```

## 1. The h2 scale — read the declarations, then measure the computed value

```sh
git show origin/main:api/assets/paper-surface/paper-surface.css > /tmp/ps.css
sed -n '323,347p;727,742p' /tmp/ps.css     # heading rules + the emitted token block
grep -n "tok-type-"  /tmp/ps.css           # ZERO hits — the namespace is --tok-reading-*
grep -n "text-wrap"  /tmp/ps.css           # ZERO hits — no `balance` anywhere
sed -n '195,219p' tooling/paper-excellence/evidence/erasure.html   # the crown spec
sed -n '76,82p'   tooling/paper-excellence/evidence/erasure.html   # artifact body = 19px
```

Measured (Playwright, `getComputedStyle`, light, 1280 and 1920, all 7 fixtures):
h2 = 27px / 600 / -0.27px / 32.4px lh / same serif family as body; body p =
18px / 400 / +0.09px / 28.8px lh. Step = **1.5x size, +200 weight, tighter
tracking and leading, NO family change, no small-caps, no text-transform**.
Artifact: `h2 { font-size: clamp(28px,4vw,38px); line-height:1.15; font-weight:400;
letter-spacing:-0.015em; text-wrap:balance }` over a 19px body → **2.0x, weight
400**. So the display leg EXISTS but is 25% short and weight-inverted, and the
artifact's eyebrow is a separate `.sec-head .label` (mono 11px / 0.18em / caps).

## 2. Per-role CPL — the rig's own probe, bucketed by role

Reproduce shoot.mjs's sampler exactly (`main p`, ≥120 chars, per-element probe
span in the element's own resolved font, median of the pool), then bucket by
`bp-role-*` class. The pool medians MUST equal the committed baselines:

```sh
python3 - <<'EOF'
import json,glob
for f in sorted(glob.glob('tooling/paper-excellence/rig/baselines/*.report.json')):
    d=json.load(open(f))
    s=[x for x in d['shots'] if x['cell'].endswith('light__1280')][0]
    print(d['label'], s['proseCpl'], s['proseCplSamples'])
EOF
```
→ 68.5/3, 71.9/19, 67.7/14, 71.6/19, 70.0/2, 71.7/26, 71.7/14 — matched
element-for-element by the re-measure, so the numbers below ARE the rig's.

| fixture | ingress CPL | body median | ratio (own text) |
|---|---|---|---|
| design-probe | 55.4 | 73.0 | 0.759 |
| eight-minute-erasure | 55.2 | 72.1 | 0.766 |
| heggemsnes-act | 55.6 | 67.7 | **0.821** |
| hobby-hardening-capstone | 57.2 | 71.6 | 0.799 |
| mechanical-spacing-doctrine | 55.8 | 70.0 | 0.797 |
| paper-excellence-wave-2026-08-12 | 56.0 | 71.7 | 0.781 |
| portabledoc-showcase | 56.6 | 71.7 | 0.789 |

Identical at 1280 and 1920 (the prose column is a fixed 660/580 above ~1120px).
Ingress is present exactly once in all seven, always 580px, always 23.04px.

## 3. The noise, isolated — canonical-text ratio

Measure the ingress and a body paragraph with the SAME probe text:

ratio = **0.783 on 7/7 fixtures at 360, 768, 1280 and 1920** (font-size ratio
18/23.04 = 0.78125). Zero spread. The 0.759–0.821 spread above is entirely
per-character sampling noise from whatever sentence each element holds, and it
eats 0.062 of the 0.069 headroom a `<=0.85` arm would have.

## 4. The flip test — inject one long pullquote and recompute the median

The real pullquotes carry `style="font-style:italic"` from walk.ex, so the probe
must be italic too (non-italic reads 56.5 CPL, italic 65.5 — a 9 CPL error).

| fixture | pool n | median before → after |
|---|---|---|
| mechanical-spacing-doctrine | 2 | **70.0 → 65.5** |
| heggemsnes-act | 14 | 67.7 → 67.5 |
| portabledoc-showcase | 14 | 71.7 → 71.4 |
| the other four | 3–26 | unchanged |

Nothing flips the 55 floor. A 66-CPL tightening reds `mechanical-spacing-doctrine`
on a two-sample pool the moment a pullquote is added — no typography defect
behind it.

## 5. Two pool members already outside the 55–75 band

* `hobby-hardening-capstone` byline (`bp-role-byline`, 0.9em = 16.2px, 580px) →
  **77.8 CPL**, above the 75 ceiling. Roles do not all narrow; this one widens
  (1.087x body).
* `portabledoc-showcase` — a body paragraph inside a columns block at 277.2px →
  **34.5 CPL**; another at **75.1**.

The median masks all three today. Any arm phrased "every paragraph in band" reds
immediately on 2 of 7 fixtures.

## 6. Section containers are unclassed (device 7 / device 3 leg 2)

`section` blocks compose to `<div style="display:flex;flex-direction:column">` —
an INLINE style and **no class** — with the eyebrow `p` and the `h2` inside it.
Confirmed in the rendered stream:

```sh
grep -o '<div style="display:flex;flex-direction:column">' /tmp/rig/design-probe.html | wc -l
```

That is why design-probe's three h2s measure `border-top: 0px; margin-top: 51.3px`
(prose rhythm) while every top-level h2 measures `2px / 91.96px / 16px`.
