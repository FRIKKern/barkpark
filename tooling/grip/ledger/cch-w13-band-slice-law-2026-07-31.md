# Re-derivation recipes — CCH wave 13 `band-slice-law` (2026-07-31)

Verifier lane `band-slice-law`. Question: does a 231px `.content` cliff at 721px
survive the prior law this epic's lineage ratified (GR67 triage, GR108/GR116
"no `max-width:768px` rule can close it", GR110 scroll affordance)?

**Measurement hygiene, load-bearing here.** The primary checkout AND the wave
worktree are both parked at `a31faa52d` ("omx(team): merge worker-2"), **201
commits behind `origin/main` `0f28d541e`**, with `cloud/priv/static/app.css`
and `app.js` diverged. Every browser measurement below was taken against a
`git archive origin/main` export in scratchpad, never the checkout. A guard run
in the checkout prints a PASS that omits the wave-12 defect entirely.

| # | Claim | Command |
|---|---|---|
| 1 | The checkout is not `origin/main`: not an ancestor, 201 behind, dirty | `git merge-base --is-ancestor HEAD origin/main; git rev-list --count HEAD..origin/main; git status --porcelain` |
| 2 | Export `origin/main` static bytes to measure against | `git archive origin/main cloud/priv/static \| tar -x -C $SP/om` |
| 3 | `overflow-guard.mjs` at `origin/main` exits 0 over FOUR defects — GR108, GR109, GR115 and `W12-narrow-viewport-truth` (the checkout's copy knows only three) | `cd $SP/om/cloud/priv/static && OVERFLOW_GUARD_PORT=4741 node __preview__/overflow-guard.mjs; echo $?` |
| 4 | The 231px cliff is REAL, exact and scenario-independent: `.content` clientWidth 720@720 → 489@721, `.app-shell` flips `column`→`row`, `.sidebar` takes a fixed 232px | `STATIC=$SP/om/cloud/priv/static PORT=4751 node $SP/cliff.mjs` |
| 5 | The cliff persists to ~952, not ~900 — `.content` regains 720px only at viewport ≈ 720+232 (measured 900→668, 901→669, 1024→792) | same as 4 |
| 6 | Page level is CLEAN across the whole band: `document.scrollWidth == clientWidth` at 620/700/719/720/721/740/768/800/860/900/901/1024/1440 × 3 scenarios, and `.content` `scrollWidth == clientWidth` at every width | same as 4 |
| 7 | Zero elements ESCAPE `.content`'s right edge at any measured width in any of 5 scenarios | `STATIC=$SP/om/cloud/priv/static PORT=4757 node $SP/cliff2.mjs` |
| 8 | The only in-band hidden content is `.status-pill-detail` (+14/+39 @721, +20 @740, +16 @780) and `.attention-reason` (+240 @800 … +40 @1000) — **both carry `text-overflow: ellipsis`**, i.e. authored, cued truncation | `git show origin/main:cloud/priv/static/app.css \| sed -n '2696,2702p;2802p'` |
| 9 | That truncation is NOT band-scoped: `.status-pill-detail` still hides 53/78px at **1100** and `.attention-reason` hides 40px at **1000**, so it is content-length tightness, not a cliff artifact | `STATIC=$SP/om/cloud/priv/static PORT=4761 SCENS=mixed-fleet,overview-past-due WIDTHS=721,740,760,768,780,800,830,860,880,900,920,952,960,1000,1100 node $SP/cliff2.mjs` |
| 10 | **MUTATION: a breakpoint-authored remedy MOVES the cliff, it does not remove it.** Patching `app.css:4241` `max-width: 720px` → `900px` makes 721-900 clean and reproduces the identical 231px drop at 901 (900→900, 901→669) | patch line 4241 in a copy, then `STATIC=$SP/mut/cloud/priv/static PORT=4771 SCENS=mixed-fleet node $SP/cliff.mjs` |
| 11 | GR67's triage routes tightness to "a NAMED child of the **successor epic**" — and the successor epic IS `cloud-console-hardening` by its own charter line 3 | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '92p'`; `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| sed -n '3p'` |
| 12 | GR116's "no `max-width:768px` rule can close it" is scoped to the TOPBAR flex-children overflow and to candidate B (raising the 720 `.topbar` padding/gap to 768) — a different element and a different fix from the `.app-shell` fold | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '502,518p'` |
| 13 | GR110's open row `gr-backlog-setmatrix-scroll-affordance` asks for exactly what wave 12's guard now asserts at 768 (sticky label column, 48px edge fade at rest → 0 at the end, reachability) | row 3's output, `notif-configured/light@768` lines; `bp task get gr-backlog-setmatrix-scroll-affordance -o json` |
| 14 | **`gr-backlog-tablet-width-audit`'s own REVIEW ADDENDUM refutes "seven screens never rendered at tablet width"** — a CDP audit already ran all **84 scenarios × {1440,768} × {light,dark} = 336 page loads**, and its two survivors (notif-matrix clip, theme-toggle topbar) are both since paid | `bp task get gr-backlog-tablet-width-audit -o json` |

Scripts `cliff.mjs` / `cliff2.mjs` live in this session's scratchpad; both are
~70 lines of native-CDP over `serve.mjs`, modelled on `overflow-guard.mjs`'s
`Cdp` class, and are re-creatable from that file.
