# cch wave 20 — re-derivation recipe: the two UNFILED normative classes

Written by the wave-20 verifier `[unfiled-quality-bar-candidates]` on 2026-08-01 against
`origin/main` = `f3e956e9247417823c7de78dc201922da538e57d`. Nothing here is committed by the
verifier; Decide commits this file.

## What it re-derives

Two person-facing classes that NO committed instrument in `cloud/priv/static/` measures:

- **(A) WCAG 2.2 SC 2.5.8 Target Size (Minimum, 24x24)** on every rendered interactive control.
- **(B) computed `font-size` below the type scale's own floor (`--text-xs: 12px`, `app.css:332`)**
  on every text-bearing element.

Axis driven: `#overview #fleet #sites #billing #activity` x `{320,390,430}` x `{light,dark}`
= 30 cells, every cell landed-view asserted (`section.view:not([hidden])`).

## Recipe

```sh
# 0. a clean origin/main tree — never the working checkout (20 worktrees share it)
SP=$(mktemp -d); mkdir -p "$SP/tree"
git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud/priv/static | tar -x -C "$SP/tree"

# 1. the probe (verifier-authored; regenerate from this file's Appendix or re-write it —
#    it is deliberately NOT committed under cloud/, it is not an instrument yet)
#    It spawns cloud/priv/static/__preview__/serve.mjs, asserts served-bytes == disk-bytes
#    (GR125(a)), drives headless Chrome over CDP with Network.setCacheDisabled (GR125(b)),
#    and per cell records for every control: {sel,tag,text,x,y,w,h} and for every element
#    with its own non-empty text node: {sel, computed fontSize}.
node "$SP/a11y-probe.mjs" "$SP/tree/cloud/priv/static"

# 2. the two adjudications (see PITFALLS — the naive versions both lie)
node "$SP/analyze.mjs"
```

## PITFALLS — each cost a wrong answer once

1. **`h < 24` is NOT "fails SC 2.5.8".** The success criterion has five exceptions; two bite
   here. The **Spacing** exception must be evaluated STRICTLY: a 24px-DIAMETER circle centred on
   the undersized target must not intersect *another target's bounding box* (for full-size
   targets) nor *another undersized target's circle*. The lenient "centre-to-centre >= 24"
   version passes all six candidates; the strict version fails one (`a.site-inst-link`, #sites).
   Report which version produced the number or the finding is unfalsifiable.
2. **The Inline exception** ("target is in a sentence, or its size is constrained by the
   line-height of non-target text") covers `a.site-inst-link` — the one control the strict
   spacing test fails. Classify inline-ness by the element's own `display` starting `inline`
   AND the parent carrying materially more text than the target.
3. **Routes are hashes, not query strings** (charter D-note in `overflow-guard.mjs` GR125(d)):
   `?scen=X` alone renders `#overview` and the whole table goes phantom. Append the hash AND
   assert the landed `section.view` id in every cell.
4. **`aria-hidden`/`hidden` ancestor walk** is required or the four hidden `section.view`s
   contribute ~600 phantom controls per cell.
5. **`--hide-scrollbars`** keeps `clientWidth == emulated width`, matching every other
   instrument in this epic. Without it the 430 cells shift ~15px.

## The numbers this produced (2026-08-01, origin/main f3e956e92)

- 810 rendered control instances measured. **6 distinct sub-24 entries; 0 fail SC 2.5.8 under
  the lenient spacing test; exactly 1 (`a.site-inst-link`, 62.58x15, #sites, 12/12 instances)
  fails STRICT spacing, and that one is covered by the Inline exception.** Sub-24 controls occur
  ONLY on `#overview` (19.5/21px) and `#sites` (15px) — `#billing`, `#fleet` and `#activity`
  have ZERO (smallest control heights 26/27/24px).
- 1560 text-bearing elements measured. **228 of 1560 instances compute below `--text-xs: 12px`**
  (histogram `10px:138 10.5px:42 11px:18 11.5px:30`), spanning **10 distinct selector/size
  pairs**, on **all five routes in both themes at all three widths**. Route-OWNED (not shell
  chrome): `#overview .instance-card-stat-k` 10px (the CPU/RAM/DISK/DOCS legend),
  `#activity .tlv-badge--audit` 10px, `#billing .dunning-plan` + `.plan-rec--due` 11px,
  `#fleet .fleet-update-chip` 11px.
- Source side: `app.css` holds **44** sub-12px `font-size` declarations (9px:1, 10px:6,
  10.5px:5, 11px:29, 11.5px:3). `__css_check.mjs` R4 counts **273** raw px font-size lines and
  is **report-only** — the run ends `0 error(s)`.

## Falsification handles

- If a future tree adds a legibility gate, this recipe's (B) half must go RED on
  `app.css:3078` before the gate can be believed.
- **DRIVEN 2026-08-01, both directions.** `.instance-card-stat-k: 10px -> 6px` (app.css:3078,
  48 rendered instances on the front screen): `__css_check.mjs` -> `0 error(s)`, R4 still 273;
  `node --test __app.test.mjs` -> 767 pass / 2 fail (both ENOENT on
  `internal/taskboard/testdata/`, identical on the UNMUTATED baseline — an artifact of the
  `cloud/priv/static`-only archive extract, not the mutation); `overflow-guard.mjs --defect
  W18-overview-card-pill` -> `28 / 28 cells clean`, `OVERFLOW GUARD PASS`, exit 0 — on the very
  card whose legend is now 6px.
- `.btn-sm { height: 28px -> 9px }` (app.css:531 — every `btn-sm` on all five routes):
  `__css_check.mjs` `0 error(s)`; `__app.test.mjs` 767/2 (same two ENOENT); overflow-guard W18
  `OVERFLOW GUARD PASS` exit 0. **A console whose small buttons are 9px tall is green on every
  committed instrument.** That non-movement IS the blindness claim, in both classes.
