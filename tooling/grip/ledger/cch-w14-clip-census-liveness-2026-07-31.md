# cch-w14 · clip-census under a per-cell render-liveness assert — re-derivation recipe

Measured against **origin/main bytes** (`885ace84aba8fde9fb42d0aba557827d2e18aa49`), exported
with `git archive` — the primary checkout is behind and lacks the W13-S4 899 block.

## 0. Export origin/main and pin the probe

```sh
D=$(mktemp -d); git archive origin/main cloud | tar -x -C "$D"
S="$D/cloud/priv/static"
```

The probe (`clip-census-liveness.mjs`) lives in the wave scratchpad, not the repo.
Its three load-bearing properties:

1. **fresh `Target.createTarget` per cell** — the SPA does not reliably re-render on
   repeat `Page.navigate`; a shared target silently returns the previous cell's DOM.
2. **explicit ready assert that throws** — `#view-<key>` exists AND `!hidden` AND
   `getBoundingClientRect().height > 0` AND a **scenario-specific sentinel selector**
   is present. Exit 2 naming every cell that failed.
3. **scenario × route axis**, not a bare `section.view` axis.

Sentinels derived by driving the DOM (`--discover`), not guessed:

| screen | scenario | hash | sentinel |
|---|---|---|---|
| Notifications | `notif-configured` | `#notifications` | `#notif-matrix` |
| API tokens | `tokens-populated` | `#settings/tokens` | `#token-list .token-row` |
| Env variables | `env-populated` | `#settings/env` | `#env-body .set-row-key` |
| Sites | `sites` | `#sites` | `#sites-body .site-row` |
| Site detail | `site-states` | `#site/<c1>` | `#site-body .deploy-row` |
| Activity | `activity` | `#activity` | `#activity-body .tlv-row` |
| Members | `members-populated` | `#settings/members` | `#members-body .set-row` |
| Providers | `providers-connected` | `#settings/providers` | `#provider-roster .prov-row` |

## 1. The census (80 cells = 8 screens × {620,700,769,785,900} × {light,dark})

```sh
CENSUS_ROOT=$S CENSUS_PORT=4293 node clip-census-liveness.mjs
```

`80 driven · 80 passed liveness · 0 FAILED · 94.5s`

Histogram **v1** (classify by computed `overflow-x`):
`A11Y 190 · SCROLLABLE 4 · ELLIPSIS 10 · CLIP_NO_CUE 0 · VISIBLE_SPILL 22`
(distinct selectors 1 / 1 / 2 / 0 / 7 = 11)

Histogram **v2** (the correct predicate — a native form control clips its own
content regardless of computed `overflow-x`; classify `SELECT/INPUT/TEXTAREA/BUTTON`
by tag):
`A11Y 190 · SCROLLABLE 4 · ELLIPSIS 10 · CLIP_NO_CUE 10 · VISIBLE_SPILL 12`
(distinct selectors 1 / 1 / 2 / **1** / 6 = 11)

The single CLIP_NO_CUE selector is `select#site-theme-select.rail-select`,
+41px at **every** width 620–900 in both themes (`sw=137 / cw=96`, painted 97.8px).

## 2. Prove the liveness refusal can fail (mutation, not reading)

```sh
CENSUS_ROOT=$S CENSUS_PORT=4295 node clip-census-liveness.mjs \
  --widths 769 --themes light \
  --only "mixed-fleet:#notifications:notifications:#notif-matrix"; echo $?
```

```
x LIVENESS mixed-fleet#notifications @769/light — sentinel #notif-matrix never present ::
  {"exists":true,"hidden":false,"h":307,"sentinel":false,"textLen":195,"hash":"#notifications"}
== CELLS: 1 driven · 0 passed liveness · 1 FAILED liveness
!! REFUSED (exit 2)
2
```

Note `hidden:false, h:307` — a liveness check without the sentinel would have
**passed** this cell and measured an empty-state box.

## 3. Prove the bare-view axis goes vacuously green

`weak-axis.mjs` = the same probe with every `scen` forced to `mixed-fleet` and
every sentinel weakened to `body`:

```sh
CENSUS_ROOT=$S CENSUS_PORT=4296 node weak-axis.mjs --widths 620,700,769,785,900 --themes light; echo $?
```

`40 driven · 40 passed liveness · 0 FAILED · exit 0`, histogram
`A11Y 0 · SCROLLABLE 0 · ELLIPSIS 0 · CLIP_NO_CUE 0 · VISIBLE_SPILL 11`.
204 of 226 measured instances vanish. Clean run, nothing driven.

## 4. The `overflow-x:auto` ruling — measure the cue, not the scrollbar

```sh
CENSUS_ROOT=$S CENSUS_PORT=4361 node cue-probe.mjs            # --hide-scrollbars
CENSUS_ROOT=$S CENSUS_PORT=4362 node cue-probe.mjs --classic  # real scrollbars
```

`.set-matrix` at 620/700/719/720/899/900/1024/1440: `over=0 TRACK=0 FADE=0px`.
At **769** `over=73 TRACK=0 FADE=48px`; at **785** `over=57 TRACK=0 FADE=48px`.
Identical under `--classic`. The reserved track is 0 in both runs, so a
"no rendered scrollbar ⇒ CLIP_NO_CUE" rule condemns a surface that is correctly
cued by `animation-timeline: scroll(self inline)` driving `--set-matrix-fade`.

## 5. VISIBLE_SPILL — walk to the nearest clipping ancestor

`cue-probe.mjs` walks each spilling element upward until `overflow-{x,y} != visible`.
For all six selectors (`div#site-body`, `div.detail-grid`, `aside.detail-rail`,
`div.rail-row`, `span.v`, `span.status-pill--neutral`, all at 900 only) the walk
reaches `<html>` **with no clipping ancestor found**, and the content right edge
lands 6–7px *inside* the viewport (`cutByViewport` = -6 … -7.09). No page overflow
was reported in any of the 80 cells. Benign.

The one element whose walk matters is the `select`: `formControl=true`,
`painted=97.8`, `intrinsic=137`, `cutByViewport=+4.2` at 620/700. A `<select>` is
UA-painted and clips regardless of `overflow:visible` — which is why the CSSOM-only
predicate scored it VISIBLE_SPILL and reported CLIP_NO_CUE = 0.

## 6. Corroborating source reads (origin/main)

```sh
git show origin/main:cloud/priv/static/app.css | sed -n '4177,4184p'   # .rail-select, max-width:60%, no appearance:none
git show origin/main:cloud/priv/static/app.css | sed -n '545,560p'     # .form-input appearance:none + select.form-input 32px chevron gutter
git show origin/main:cloud/priv/static/app.js | grep -n 'rail-select'  # 9635, one call site
```

## 7. Extension sample (8 more scenario×route cells) — and the refusal's cost

```sh
CENSUS_ROOT=$S CENSUS_PORT=4390 node census-v2-ext.mjs --widths 620,769,900 --themes light; echo $?
```

`24 driven · 15 passed liveness · 9 FAILED liveness · exit 2`.
All nine failures were **my sentinel selectors being wrong**, not empty views
(`billing-past-due#billing` reported `textLen:1088`, `usage-quota` `textLen:560`).
The refusal fails LOUD rather than silent — the intended shape — but the sentinel
table is real maintenance surface a new screen must extend.

Extension histogram over the 15 live cells:
`A11Y 0 · SCROLLABLE 0 · ELLIPSIS 2 · CLIP_NO_CUE 0 · VISIBLE_SPILL 11 (7 selectors)`.
No new CLIP_NO_CUE selector appeared.

## 8. Free corroboration: the #fleet band residue, measured by width

```sh
CENSUS_ROOT=$S CENSUS_PORT=4395 node cue-probe.mjs   # "FLEET band" section
```

```
@720 doc 720/720   @769 doc 790/769   @785 doc 790/785
@799 doc 799/799   @820 doc 820/820   @899 doc 899/899   @900 doc 900/900
```

`documentElement.scrollWidth` is **pinned at 790** through the broken band, so the
band is `[769, 789]`, not "769–785": at 769 the page scrolls +21px, at 785 +5px,
and it is clean from 799 up and at 720 down. 21 matches `FLEET_ROW_RESIDUAL.max`
in `overflow-guard.mjs`. No ancestor clips it — `.content` and `.shell-main` both
compute `overflow-x: visible` and carry the same 558 vs 537 overrun at 769.
