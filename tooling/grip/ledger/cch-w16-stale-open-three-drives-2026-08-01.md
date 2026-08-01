# cch-w16 — the three stale-open rows that cannot close on a merge SHA (re-derivation recipe)

Verifier `v-stale-open-three-drives`, 2026-08-01. Driven on **origin/main bytes**
(`c48fb17d5`), Chrome 150.0.7871.187, node v22.22.0, `--hide-scrollbars`.
Nothing here is committed by the verifier; Decide owns the commit.

## 0. Cut a clean tree of main's static bytes (never measure the working checkout)

    SP=$(mktemp -d)
    git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud/priv/static | tar -x -C $SP

Note: the PRIMARY checkout does **not** carry `__preview__/breakpoint-sweep.mjs`;
`origin/main` does. Measuring the checkout measures a stale tree (charter D125).

## 1. The shipped guard on main bytes

    cd $SP && OVERFLOW_GUARD_PORT=4479 node cloud/priv/static/__preview__/overflow-guard.mjs

`OG_RC=0`. `W13-detail-route-band` prints `108 / 108 cells clean`,
`W15-fleet-row-text-bounded` prints `42 / 42 cells clean (154 fleet rows measured,
2 known-row cells itemised: cch-w15-bl-fleet-support-detail-truncated-stacked-band)`.

## 2. The three drives (`drive.mjs`, verifier probe, NOT committed)

Copy `overflow-guard.mjs`'s CDP plumbing (chrome discovery, `Cdp` class,
`setViewport`, `nav`) into `$SP/cloud/priv/static/__preview__/drive.mjs`, then:

    cd $SP && DRIVE_PORT=4471 node cloud/priv/static/__preview__/drive.mjs
    cd $SP && ONLY_B=1 DRIVE_PORT=4473 node cloud/priv/static/__preview__/drive.mjs

**DRIVE A** — 11 fixtures x 13 widths x 2 themes = 286 cells. Fixtures: the six
`BAND_ROUTES` plus `fleet-v4`, `sites`, `billing-trial`, `overview-past-due`,
`notif-configured`. Widths `721 750 768 769 775 780 785 790 800 830 860 899 900`.
Assert `documentElement.scrollWidth <= clientWidth` AND the landed
`section.view:not([hidden])#id` per cell.
Main reads: **286 cells rendered, 0 OVERFLOW, 0 misrouted, 0 render errors.**

**DRIVE B** — `.content getBoundingClientRect().top` at widths 320/390/430/620/720
x heights 800/667/390, budget `0.4H` (the shipped `max-height: calc(40vh - 60px)`
gives `0.4H - 4` exactly).
Main reads: **316@800 (budget 320), 262.8@667 (266.8), 152@390 (156)** at every
width, `is-nav-clipped=true`, `--nav-fade: 40px`.

**DRIVE C** — at 769, both themes, `mixed-fleet` and `fleet-v4`: every
`.fleet-name` / `.fleet-url` must have `scrollWidth <= clientWidth`.
Main reads: **0 shredded in all four cells**, page `scrollWidth 769 == 769`.

## 3. MUTATION PROOFS (a drive that cannot lose is not a drive)

**A + C** — collapse the split back to pre-#8609:

    perl -i -pe 's/\@media \(max-width: 899px\) \{/\@media (max-width: 768px) {/ if $. == 2169' \
      $SP/cloud/priv/static/app.css

DRIVE A goes to **58 OVERFLOW / 286** (`instance-detail 14, site-rollback 14,
site-states 16, fleet 8, fleet-v4 6`), first offender
`instance-detail/light@769: scrollWidth 837 > viewport 769`.
DRIVE C goes to **5/5/8/8 shredded**, e.g.
`fleet-url#9 151>19 "staging-5b2c1e.barkpark.cloud"`.

**B** — remove the strip cap:

    perl -i -pe 's/max-height: calc\(40vh - 60px\);/max-height: none;/' $SP/cloud/priv/static/app.css

Every cell goes `!! OVER` at **522.88px**, `clipped=false`, `fade=0px` — and at
390-tall landscape 522.88 > 390, i.e. the rendered view is entirely below the fold.
(522.88, not the pre-#8655 745.88: the `.nav-group` disclosure still ships.)

Restore `app.css` from a pre-mutation copy and `diff -q` it before believing any
subsequent green.

## 4. Ledger adjudication (what the drives license)

| row | merge SHA | drive | verdict |
|---|---|---|---|
| `cch-w13-s4-tablet-band-detail-routes` | #8609 `d6a985a` | A | criterion 2 is FALSE BY PREMISE, not unproven — see §5 |
| `cch-w13-bl-folded-shell-nav-wall` | #8655 `aec3be3` + #8739 `4cbebf1` | B | closeable |
| `cch-w13-fleet-row-band-769-785` | #8656 `caafb5f` | A, C | closeable |
| `cch-w14-s3-fleet-row-band-899-split` | #8656 `caafb5f` | C | criterion 2 evidence supplied here |

## 5. cch-w13-s4 criterion 2 CANNOT be stamped as written

Its text is `the same 143-cell sweep (11 fixtures x 13 widths, both themes) goes
from 21 OVERFLOW cells at origin/main to 0`. Three numbers in one sentence are
wrong, and PR #8609's own body says so: the sweep is **11 x 13 x 2 = 286 cells**
and the movement was **56 -> 8**, with the residual 8 filed as
`cch-w13-fleet-row-band-769-785`. `overflow-guard.mjs:52-56` on main carries the
same number in shipped code ("56 of 286 cells"). The PR states outright:
"criterion 2 is honestly UNMET with a `--miss` note, because the brief's
'21 cells -> 0' premise did not reproduce."

So the honest close RESTATES the criterion (286 cells, 56 -> 8, residual 8 now 0
since W14-S3 removed the pin) and stamps it against §2 DRIVE A. Stamping the
sentence as written would record a number nobody ever measured.

## 6. The audit row names 10; the real set is 13, and 5 of the 10 self-closed

`cch-w15-bl-stale-open-wave13-slice-rows` (`bp task get` it) names ten rows.
Re-read from the server on 2026-08-01:

- **DONE already, closed 2026-08-01T04:31-04:32Z** — ~4h AFTER the audit row was
  filed at 00:16:04Z: `task-1f8bcab494ac0a3a` 7/7, `cch-w13-s2-...` 8/8,
  `cch-w13-s3-...` 9/9, `cch-bl-provider-rotation-identity-echo` 7/7,
  `cch-w13-s6-ledger-truth-closes` 9/9. The audit's list is already half-discharged.
- **Still open, named**: `cch-w13-s4-...` (8/10), `cch-w13-bl-folded-shell-nav-wall`
  (0/3), `cch-w13-bl-rail-select-clipped-every-width` (0/3),
  `cch-w13-bl-preview-cancel-becomes-site-freshness` (0/3),
  `cch-w13-fleet-row-band-769-785` (0/3).
- **Open, NOT named — the three that make 13**:
  `cch-w14-s3-fleet-row-band-899-split` (6/7, PR #8656 merged, criterion 2 empty),
  `drafts.cch-w15-s5-site-open-phone-overflow` (0/8, **status `draft`**),
  `drafts.cch-w15-s5-site-link-phone-width` (0/8, **status `draft`**).

The two `drafts.*` twins are a THREE-way duplicate: the row that actually shipped
is `cch-w15-s5-site-link-phone-band` (done, 8/8, PR #8743 `b1c80eda`, whose
`Task:` trailer names it). Both twins are unpublished drafts sitting in the epic's
open count — cancel, do not close.
