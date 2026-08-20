# cch-w18 s8+s3 residue — re-derivation recipes (wave 18 VERIFY, 2026-08-01)

Everything below was DRIVEN in headless Chrome against a pristine
`git archive origin/main` copy (b266a1a5e), never against a worktree.

Bring-up used by every recipe:

    D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x -C $D
    cd $D && export CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

## R1 — Is the billing phone page scroll dead on merged main? (s8 residue, crit 2)

    node cloud/priv/static/__preview__/breakpoint-sweep.mjs --render --widths 320,340,360,375,390 --cell billing-trial

VERDICT: DEAD. `>> verdict 6 measured defects (Q1 0 · Q2 6 · Q3 0) — exit 1`.
Q1 is the page-sideways quadrant and it is ZERO. The 6 Q2 findings are
`select#bp-theme-picker` sw 72 > cw 59/65/70 at 320/340/360 both themes — the
THEME-PICKER row the wave-18 topbar slice owns, not the tier grid.
Confirmed independently by a full-DOM rect walk (R2), which the sweep does not do.

## R2 — Full-DOM rect walk + the 901 control (s8 residue, crit 2)

Driver: `scratchpad/drive18.mjs` PART B (serve.mjs + CDP
`Emulation.setDeviceMetricsOverride`; a `resize` call floors at 500 on this host).
Asserts `documentElement.scrollWidth == clientWidth` AND walks every element,
flagging any `getBoundingClientRect().right > clientWidth + 0.5`.

    billing-trial/light  320:320/320 340:340/340 360:360/360 375:375/375 390:390/390 901:901/901
    billing-trial/dark   320:320/320 340:340/340 360:360/360 375:375/375 390:390/390 901:901/901
    901 #billing-tiers grid-template-columns = "283.5px 283.5px" sw/cw 579/579  cta sw/cw 240/240

12/12 cells, ZERO rect-walk overhangs. 901 still computes TWO tracks and the CTA
is not clipped, so the remedy did not re-open the tier-CTA clip.

## R3 — The BEFORE numbers are NOT on origin/main. Anchor them to cee6024ab.

    git show origin/main:cloud/priv/static/app.css | grep -c "max-width: *900px"   # 0
    git rev-parse 626466a0c^                                                        # cee6024abf1a…
    git show cee6024ab:cloud/priv/static/app.css | grep -n "max-width: *900px"      # 1051

`626466a0c` (= PR #8851 mergeCommit) is the s8 commit; its TRUE pre-merge parent
is `cee6024ab`, not `97a581f6d` (which is an older ancestor that also still
carries the rule, so it works as an anchor but is not the parent).
Same driver, ROOT = an archive of `cee6024ab`:

    billing-trial/light  320:413/320X 340:413/340X 360:413/360X 375:413/375X 390:413/390X 901:901/901
    billing-trial/dark   320:413/320X 340:413/340X 360:413/360X 375:413/375X 390:413/390X 901:901/901
    @320 7 overhangs, worst div right 413.22 (by 93.22) · @375 by 38.22 · @390 by 23.22

93/38/23 reproduce the filed criterion-1 numbers exactly. 340 (73.22px) and 360
(53.22px) had never been driven by anyone. 901 was ALREADY clean before, so the
"without re-opening the CTA clip at 901" clause is satisfied trivially.

## R4 — Were the co-scoped obligations paid in the SAME commit? (s8 residue, crit 3)

    git show 626466a0c --stat

app.css + breakpoint-sweep.mjs + breakpoint-sweep.test.mjs + cssom-heads.baseline
+ overflow-guard.mjs, all in one commit. The pinned axis literal:

    git show origin/main:cloud/priv/static/__preview__/breakpoint-sweep.test.mjs | grep -n "assert.deepEqual(WIDTHS"
    → [619,620,621,719,720,721,767,768,769,829,830,831,898,899,900]   # FIFTEEN

    git show origin/main:cloud/priv/static/__preview__/cssom-heads.baseline | grep -vE '^#|^$'   # 1252

## R5 — cch-w14 crit-1's OWN axis, driven (the guard does NOT cover it)

`BAND_WIDTHS = [721,768,769,790,830,860,899,900,1024]` (overflow-guard.mjs:242).
The filed axis is `{320,390,620,899,900,901,1024,1440}` — only 899/900/1024 overlap.
Driver: `drive18.mjs` PART A, 4 scenarios (site-states + all three site-binding)
x 8 widths x 2 themes = 64 cells, four metrics per pill.
Scenario deep links are READ FROM `scenarios.mjs` (each binding fixture has its
own site id; hard-coding `SITE` hangs the nav).

    site-states/light  320:ok(p145/145 h40/40 l109/109 dR-12) 390:ok(p166/166 h22/22 l130/130 dR-12) … 1440:ok(p117/117 h40/40 l81/81 dR-12)
    TOTAL 0 violations

The filed BEFORE deltas (+17.52 at >=900, +10.31 on binding, +8.52 at 320) are all
NEGATIVE now: label.right − pill.right == −12.00 in all 64 cells.

## R6 — Is the W15 fleet green VACUOUS? (mutation, distrust-vacuous-green)

    node cloud/priv/static/__preview__/overflow-guard.mjs --defect W15-fleet-row-text-bounded   # rc 0, 90/90
    # then delete `.fleet-status .status-pill { … }` from the archived app.css and re-run:
    → rc 1, 68 findings; fleet-support-failed reds at 320/360/390/430/620/721/769/800/830/860
      and is CLEAN at 899/900/940/983/1000.

That is the band, measured: **320-860**, not the filed title's "721 and 769".
The mutant reproduces the filed numbers verbatim: `row1 .status-pill-detail:
scrollWidth 463 > clientWidth 295` @721 and `> clientWidth 343` @769, both themes.

## R7 — The filed sentence is MIS-QUOTED, in the row AND in merged app.css

    drive18.mjs PART C on merged main, fleet-support-failed#fleet:
    @721 .status-pill-detail sw 295 cw 295, pill sh 40 ch 40, page 721/721
    TEXT "verify: no heartbeat within the provisioning budget (listener never came online)"

The task row and the merged app.css banner both say "…within the provisioning
window". The real string ends "…provisioning budget (listener never came online)".
Both prose sites inherited a 40-char slice from overflow-guard's own fail message
(`(e.textContent||'').slice(0,40)`) and completed it by guess.
