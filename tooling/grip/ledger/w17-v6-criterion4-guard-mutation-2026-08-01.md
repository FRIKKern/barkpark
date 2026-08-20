# Re-derivation recipe — W17 v6, criterion 4 of `cch-w14-bl-status-pill-label-overflows-rail` (2026-08-01)

Criterion 4 reads: *"Whatever instrument covers this asserts at a width >= 900,
and is proven able to fail there — a guard scoped below 900 passes while the
defect stands."* This is the COMMITTED guard losing, not a bespoke probe.

## R8 — mutate the merged tree, run the committed W13 leg

```bash
D=$(mktemp -d); git archive 17ec78adc cloud/priv/static | tar -x -C $D
D2=$(mktemp -d); cp -R $D/cloud $D2/
cd $D2/cloud/priv/static && python3 -c "
lines=open('app.css').readlines()
assert lines[5256].startswith('.detail-rail .status-pill {')
assert lines[5266].startswith('.detail-rail .status-pill-label')
open('app.css','w').writelines(lines[:5256]+['/* MUTATION */\n']+lines[5267:])"
cd $D2/cloud/priv/static/__preview__
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  OVERFLOW_GUARD_PORT=4851 node overflow-guard.mjs --defect W13-detail-route-band
```

`rc=1`, `OVERFLOW GUARD FAIL — 8 finding(s) in: W13-detail-route-band`, all eight
at **900 and 1024** (site-states + site-rollback x light/dark), each naming the
victim:

```
✗ site-states/light@900 .detail-rail .status-pill: scrollWidth 155 > clientWidth 117
  — 25% of "No content binding" renders OUTSIDE its own chip (the label declares
  no overflow, so it is painted, not clipped) and the page never scrolls, which
  is why every page-level leg above walks past it
```

The same leg on the UNMUTATED merged tree prints
`108 / 108 cells clean` + `36 .detail-rail .status-pill(s) measured on both axes,
0 outside their own chip`.

NOTE THE LEG'S OWN LOWER BOUND: `BAND_WIDTHS` starts at 721, so this guard is
structurally blind to the row's 320 cell (driven pre-fix at +10, post-fix clean —
see `w17-v6-free-close-residue-2026-08-01.md` R5). Criterion 4 asks only about
>= 900 and is satisfied; the 320 half is covered by hand-driven measurement, and
that distinction must be stated rather than folded into the guard's green.
