# Re-derivation recipes — cch-w18 topbar cascade destination, proved by mutation (verify, 2026-08-01)

All recipes run against a `git archive origin/main` export, never the working
checkout. Base sha256 of `cloud/priv/static/app.css` on origin/main
`b266a1a5e`: `81d085a0391ab7aa14ab916d78bb0d2077e37bbeb257decb457c4fd1cb8a633e`
(241620 B). Chrome 150.0.7871.187, node v22.22.0, macOS.

```bash
D=$(mktemp -d)
git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x -C $D
git -C /Volumes/SATECHI/github/barkpark show origin/main:cloud/priv/static/app.css > /tmp/main-app.css
BLOCK='
@media (max-width: 430px) {
  .topbar { height: auto; min-height: 56px; flex-wrap: wrap; padding: 6px 12px; }
  .topbar-right { flex-wrap: wrap; justify-content: flex-end; gap: 6px; }
  .billing-chip { flex: 0 0 auto; }
}
'
```

The driver `drive-topbar.mjs` is reproduced at the bottom; it is a 120-line CDP
client modelled byte-for-byte on `overflow-guard.mjs`'s bring-up (same Chrome
flags incl. `--hide-scrollbars`, same GR125a served==disk assertion, same
nav-poll). It prints `.topbar` computed padding / column-gap / height /
flex-wrap, `.topbar-right` flex-wrap / gap / justify, and every
`.topbar-right` child's clientWidth vs scrollWidth.

## R1 — the cascade trap: position (a), BEFORE the 830 block

```bash
cd $D
{ sed -n '1,2326p' /tmp/main-app.css; printf '%s' "$BLOCK"; sed -n '2327,$p' /tmp/main-app.css; } \
  > cloud/priv/static/app.css
node drive-topbar.mjs $D/cloud/priv/static 320 8392
```
Expect: `padding=0px 14px`, `.topbar-right gap=8px` — the 430 block's
`padding: 6px 12px` and `gap: 6px` are SILENTLY DISCARDED by the later
`@media (max-width: 830px)` block at app.css:3910-3915 at equal (0,0,1,0)
specificity. `flex-wrap=wrap` on BOTH `.topbar` and `.topbar-right` and
`justify=flex-end` SURVIVE (nothing later declares them). `height=106.5`.

## R2 — position (b), immediately AFTER app.css:3915

```bash
{ sed -n '1,3915p' /tmp/main-app.css; printf '%s' "$BLOCK"; sed -n '3916,$p' /tmp/main-app.css; } \
  > cloud/priv/static/app.css
node drive-topbar.mjs $D/cloud/priv/static 320 8393
```
Expect: `padding=6px 12px`, `.topbar-right gap=6px`, `height=116.5`. Fully alive.

`.topbar` `column-gap` reads **10px at BOTH positions** — that is NOT a cascade
loss, the D195 block never declares `gap` on `.topbar`. Only PADDING (on
`.topbar`) and GAP (on `.topbar-right`) are contested.

## R3 — the BEFORE table for task-9fcf92e7a02fa5b8 / the trial+picker rows

```bash
cp /tmp/main-app.css cloud/priv/static/app.css
node drive-topbar.mjs $D/cloud/priv/static 320 8391
node drive-topbar.mjs $D/cloud/priv/static 430 8396
```

## R4 — both halves of the 430 axis obligation, each red on its own

```bash
# CSS without BREAKPOINTS  -> UNCOVERED
cp /tmp/main-app.css cloud/priv/static/app.css
printf '\n@media (max-width: 430px) {\n  .topbar { flex-wrap: wrap; }\n}\n' >> cloud/priv/static/app.css
node cloud/priv/static/__preview__/breakpoint-sweep.mjs; echo "rc=$?"   # 2, UNCOVERED breakpoint 430px

# BREAKPOINTS without CSS  -> PHANTOM
cp /tmp/main-app.css cloud/priv/static/app.css
sed -i '' 's/^export const BREAKPOINTS = \[620, /export const BREAKPOINTS = [430, 620, /' \
  cloud/priv/static/__preview__/breakpoint-sweep.mjs
node cloud/priv/static/__preview__/breakpoint-sweep.mjs; echo "rc=$?"   # 2, PHANTOM breakpoint 430px
```

## R5 — the sidecar suite, with BOTH halves applied

```bash
node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs
```
Expect `# fail 2`: `not ok 13` (the WIDTHS literal at test.mjs:146) and
`not ok 43` (D200's post-condition clamp at test.mjs:503, which pins the
mutated declared axis as `[720, 768, 830, 899]`).

## R6 — the baseline price

```bash
{ sed -n '1,3915p' /tmp/main-app.css; printf '%s' "$BLOCK"; sed -n '3916,$p' /tmp/main-app.css; } \
  > cloud/priv/static/app.css
node cloud/priv/static/__preview__/cssom-parity.mjs
```
Expect `BASELINE MISMATCH: 1255 authored rule heads, sidecar baseline is 1252 (+3)`,
flattened selectors `1218/1218` (unchanged — all three selectors already exist
elsewhere, so the signature is a pure block ADD, not a swallow).

## R7 — no leg measures the chip below 721

```bash
git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs | \
  grep -nE '^const (WIDTHS|CHIP_WIDTHS|PHONE_WIDTHS|FLEET_WIDTHS)'
git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs | grep -n 'billing-chip'
```
`CHIP_WIDTHS` starts at 721; the `PHONE_WIDTHS` leg (`W12-narrow-viewport-truth`,
:747-780) asserts page scrollWidth and `.instance-card` fit only and never
touches `#billing-chip`.

## R8 — the width-count prose sites

```bash
git grep -nE "13 width|13-width|338 headless|338 cells|x 13 widths" origin/main -- cloud .github .claude
```

---

## drive-topbar.mjs

Kept out-of-tree deliberately (a verifier writes no instrument into `cloud/`).
Regenerate by copying `overflow-guard.mjs`'s `Cdp` class, `findChrome`, the
serve+GR125a block and the Chrome spawn verbatim, then evaluating:

```js
(function(){
  var t=document.querySelector('.topbar'); var cs=getComputedStyle(t);
  var r=t.getBoundingClientRect(); var tr=document.querySelector('.topbar-right');
  var trcs=getComputedStyle(tr);
  return {padding:cs.padding, colGap:cs.columnGap, height:Math.round(r.height*100)/100,
          computedHeight:cs.height, minHeight:cs.minHeight, flexWrap:cs.flexWrap,
          trFlexWrap:trcs.flexWrap, trGap:trcs.columnGap, trJustify:trcs.justifyContent,
          kids:[].slice.call(tr.children).map(function(k){
            return {id:k.id, cw:k.clientWidth, sw:k.scrollWidth,
                    top:Math.round(k.getBoundingClientRect().top*100)/100};})};
})()
```
Navigate `?scen=billing-past-due&theme={light,dark}`, ready-poll on
`document.querySelector('.topbar-right')`, `Emulation.setDeviceMetricsOverride`
to 768 first then to the target width, sleep 120ms, then evaluate.
