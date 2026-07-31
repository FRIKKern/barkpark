# Re-derivation recipes — jarl.no measured widths + capture-rig wall clock (Epic 9 wave 1, 2026-07-31)

Verifier lane [measured-widths]: replace the width survey's cascade arithmetic with
browser truth from a real production build, settle the `.shell`-inert-vs-pinning
contradiction, clock the "one command, all routes" capture rig, and preserve the
session-tmp rig scripts before they vanish the way the frick generator did.

Setup for every row below (Next 15 production build, NOT `next dev`):

    cd /Users/frikkjarl/Documents/GitHub/jarl-website && pnpm build && (pnpm start &)
    # measurement scripts run against http://localhost:3000 with
    # NODE_PATH=<scratchpad>/node_modules (playwright 1.x installed there)

Measured at git `9262f52` (== `origin/main` at time of writing).

| # | Claim | Command |
|---|---|---|
| 1 | Build is green and prerenders 31 routes; the site is measurable locally at all | `cd jarl-website && pnpm build 2>&1 \| tail -5` (→ exit 0) |
| 2 | The live sitemap yields exactly **31** routes: 5 static + 18 `/prosjekter/*` + 1 `/notater/*` + 7 `/papers/*` — this is the rig's route source of truth | `curl -s http://localhost:3000/sitemap.xml \| grep -oE '<loc>[^<]+' \| sed 's\|<loc>\|\|;s\|https://jarl.no\|\|' \| tee /dev/stderr \| wc -l` |
| 3 | Tokens as they compute in the browser: `--measure: 42rem` → **672px**, `--site-width: 70rem` → **1120px**, `--space-5: 1.5rem` → 24px, `--text-hero: clamp(3.25rem, 1.2rem + 9.5vw, 8.5rem)` | `node <scratchpad>/measure-widths.mjs \| grep -m1 tokens` |
| 4 | **Band `.inner` measures 1120px border-box at 1440** (the 70rem cap binds), content box 1072px after 2×24px padding; at 390 it is 390px border-box / 342px content | `node <scratchpad>/measure-widths.mjs` → rows `bandInner` |
| 5 | Body char width is **11.33px** (Instrument Sans @ 17px), so **1072px = 94.6ch** and **672px = 59.3ch** — the figure measure and the prose measure in reading units | same script; `ch` computed by measuring a hidden `<span>0</span>` in the element's own computed `font` |
| 6 | **The survey's "1.6× jump" premise is STALE.** HEAD `9262f52` ("one reading measure — prose takes --measure, figures keep the shell") already lands the two-measure system: prose inside `.bp-paper-surface` measures **672px / 59.3ch**, figures (`.bp-lineage`, `table`) **1072px / 94.6ch**, both flush at `left: 184px` | `node <scratchpad>/verify.mjs \| head -3` · `git show --stat 9262f52` |
| 7 | The fix is an **ad-hoc 21-selector `>` allowlist**, not a token — a fourth width opinion rather than a doctrine; the figure measure 1072px is emergent (site-width − 2×space-5) and exists in no token | `sed -n '302,346p' jarl-website/src/app/globals.css` |
| 8 | **`.shell` / `.storyShell` are INERT** — contradiction settled in favour of "inert": measured 1072px against their own `max-width: 1120px`, so the cap never binds and the width comes entirely from the Band inner content box | `node <scratchpad>/measure-widths.mjs` → `shell: 1072px … (mw=1120px)` on `/prosjekter/scaffy` |
| 9 | `.bp-paper-surface` carries **no width of its own** (`max-width: none`) — it fills whatever the host shell gives it, confirming the engine ships zero surface width | same script → `paperSurf: 1072px … (mw=none)` |
| 10 | **The home page already reads below the comfortable floor:** the two Prose columns measure 565.81px / **49.9ch** (ingress) and 444.56px / **39.2ch** (`Sections .head`) at 1440 — the 42rem cap is a ceiling that never binds there | `node -e` snippet querying `[class*="Prose-module"]` on `/`; full script `<scratchpad>/measure-widths.mjs` |
| 11 | On a full-width section the Prose cap *does* bind: `/notater/velkommen` prose = **672px / 59.3ch** | same script → `/notater/velkommen` row |
| 12 | **The hero title does NOT overflow at 390.** Box 342px, text 10.0ch, `font-size: 56.25px`, `max-width: 13ch = 464.12px` (non-binding), `scrollWidth == clientWidth == 342` | same script → `hero: 342px/10ch … ovf=false` |
| 13 | At 1440 the hero is 753.88px / 9.8ch at `font-size: 136px`; its `max-width: 13ch = 1047.54px` also never binds | same script → desktop `hero` row |
| 14 | **REAL DEFECT, desktop-clean / mobile-only: 104px of horizontal page scroll at 390** on exactly 2 live routes — `/prosjekter/scaffy` and `/papers/scaffy-historien` (`documentElement.scrollWidth 494 vs clientWidth 390`), in BOTH colour schemes | `node <scratchpad>/verify.mjs \| sed -n '/390 overflow census/,$p'` |
| 15 | Culprit is the vendored engine's `.bp-lineage__body`: `scrollWidth 292 > clientWidth 164`, caused by the unbreakable 408px token `"frontend/app/{{.pageTypePlural}}/(index)/page.tsx"` in a `minmax(150px, 1fr)` grid cell with `overflow-wrap: normal` | `node <scratchpad>/ovf4.mjs` · `grep -n 'bp-lineage__body\|bp-lineage__nodes' <extracted>/package/dist/paper-surface.css` (lines 1029, 1035 — no `overflow-wrap`) |
| 16 | It is the *engine*, not jarl, that lacks the guard: the same stylesheet DOES ship `overflow-x: auto` scroll wrappers for heatmaps (`.bp-heat__scroll`), so the omission on lineage is inconsistent, not a policy | `sed -n '1028,1041p' <extracted>/package/dist/paper-surface.css` |
| 17 | 10 live routes render `bp-lineage` (5 projects + 5 papers) and 2 render `bp-duel`, so the class of bug is fleet-wide even though only the scaffy pair has a long enough token to break today | `for r in $(curl -s localhost:3000/sitemap.xml \| grep -oE '<loc>[^<]+' \| sed 's\|<loc>\|\|;s\|https://jarl.no\|\|'); do h=$(curl -s "localhost:3000$r"); echo "$r lineage=$(echo "$h"\|grep -c bp-lineage) duel=$(echo "$h"\|grep -c bp-duel)"; done \| grep -v 'lineage=0 duel=0'` |
| 18 | **Wall clock for "one command, all routes": 481.9s (8m02s) for 124 captures = 3.89s/capture**, 0 failures, 1 retry, 35MB of fullPage PNGs — 31 routes × {1440×900, 390×844} × {light, dark} | `cd <scratchpad> && /usr/bin/time -p node shoot-matrix2.mjs` → `DONE captures=124 failures=0 retries=1 wall=481.9s per_capture=3.89s` |
| 19 | **`waitUntil: 'networkidle'` is unusable on this site** — it timed out at 30s on `/papers/scaffy-historien` on a warm server; the rig must use `'load'` + `document.fonts.ready` | first `ovf3.mjs` run → `page.goto: Timeout 30000ms exceeded … waiting until "networkidle"` |
| 20 | **A rig that screenshots before fonts settle silently lies about overflow.** v1 (`'load'` + 250ms) reported overflow on the *bulldocs* pair and missed scaffy; v2 (`+ fonts.ready`) reports the scaffy pair and nothing else; a third fonts-settled pass reproduces v2 exactly. Overflow assertions are only valid after `document.fonts.ready` | compare `<scratchpad>/shots/audit.json` vs `<scratchpad>/shots2/audit.json` vs `verify.mjs` census |
| 21 | v1 (no font wait, no retry) also cost **2/124 hard failures** (20s goto timeouts on `/prosjekter/svgloop` and `/papers/spreadsheet-wizard-historien`) and 660s of screenshot span — the one-retry loop in v2 removed both | `node -e "const a=require('<scratchpad>/shots/audit.json'); console.log(a.filter(x=>x.error))"` |
| 22 | `pnpm check` does NOT run `check:sources`; CI runs it as its own step and it is a HARD gate (exits 2 without `BARKPARK_READ_TOKEN`). Gates are genuinely blocking on push+PR to main | `node -e "console.log(require('jarl-website/package.json').scripts.check)"` · `cat jarl-website/.github/workflows/ci.yml` |
| 23 | `scripts/check-tokens.mjs` today only polices **colour** literals + the satori palette mirror — it contains no width/measure logic, so the width gate is net-new surface, not an edit to an existing rule | `sed -n '1,55p' jarl-website/scripts/check-tokens.mjs` |

## Preserved rig scripts (were session-tmp only)

Verbatim copies of `shoot.mjs`, `shoot2.mjs`, `probe.mjs`, `interact.mjs` (plus
`interact2.mjs`, `probe2.cjs`) and the new `measure-widths.mjs` / `shoot-matrix2.mjs` /
`ovf4.mjs` / `verify.mjs` are reproduced in the bp task report for this lane. They lived
only in
`/private/tmp/claude-501/-Users-frikkjarl-Documents-GitHub/2938d290-.../scratchpad/`
and are one `/tmp` sweep from lost — the same loss mode that took the frick generator.
