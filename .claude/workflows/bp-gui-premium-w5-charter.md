# GUI premium — reader visuals at TUI quality — W5 charter (slate-2 fidelity + reader chrome)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The **self-update W5** charter formerly here is preserved verbatim at
> `.claude/workflows/bp-self-update-w5-charter.md` (also committed in #2227). This file is
> the memory of the **gui-premium** epic from wave 5 onward. Earlier gui-premium waves live
> in `.claude/workflows/bp-email-fleet-charter.md` (w3/w4 email detour) and the gp-w1/gp-w2
> task evidence.

Epic anchor: bp task slug **`gui-premium`** (published, open, priority 1, GitHub #1598,
6 done children gp-w1..email-prose-polish). Acceptance surface: `/papers/portabledoc-showcase`
on guerrilla. Anchor's literal scope (issue #1598, verbatim): "(w1) diagrams in style …;
(w2) slate parity — native premium HTML/SVG renderers for **stat/stats/heatmap/chart**
instead of Unsupported boxes; (w3) reader chrome polish pass."

## Vision

Open the showcase paper in the browser and the four slate dataviz types render at the same
bar the terminal hits — including the slate-2 richness the TUI shipped after gp-w1 closed:
a GitHub-style calendar heatmap with Σ marginals and exact values (quantile dual-encoded,
never color-only), stat tiles with dim /denominator suffixes, charts whose big-value y-axes
read "40k" not "40000". Print the paper and it paginates cleanly — screen chrome hidden,
figures unbroken — the way the Sheets reader already does. And when a block type the reader
does not know arrives, it degrades into an honestly-styled box, not a bare unstyled div.
All of it on the ONE shared render path (data_viz.ex → compose.ex → paper-surface.css),
article emitters extended additively, email emitters byte-untouched.

## Non-negotiable operational facts (builders read FIRST)

- Worktrees from origin/main after `git fetch`. Claim your bp task BEFORE working. PR body
  carries `Task: <id>`. `.ex/.heex` changes WAIT for the Elixir Test CI gate before merge.
- Email emitters are gate-locked byte-untouched: never edit `*_email_html` functions,
  `Util.escape_html`, `Palettes.email_skin/font_mono`, `TokensGen` — bytes would move in all
  four email families at once. `email_golden.html` must stay byte-identical
  (`git diff --exit-code` on it is a per-slice gate).
- Goldens: DataViz types are deliberately OUTSIDE both email_golden and
  `GenGoldenParity.types/0` — new coverage is plain assertions in `data_viz_test.exs`,
  no golden regen owned by any slice this wave.
- No tokens.json / emit.mjs / tokens_gen.* change is needed or allowed: article dataviz
  color is the `--paper-accent` / `--bp-tone-*` / `color-mix` + inline `--i` idiom
  (verified: `pdrenderChart`/`pdrenderHeatmap` token families sink ONLY into Go).
- paper-surface.css: hand-authored regions only; never touch the two GENERATED blocks.
  Gates: `node design/emit.mjs` (check mode) + `bash scripts/paper-editor-mirror-check.sh`.
- The six render gates exist and are green at HEAD (87 tests): article_class_coverage,
  email_golden, data_viz, component_golden_parity, view_edit_parity,
  canvas_reader_parity_gate — all under `api/test/barkpark/portable_doc/render/`.
- The browser reader's default path is the Elixir compose path. The embedded pdrender WASM
  is an opt-in TUI-toggle novelty (`body.bp-tui`, lazy-loaded) — it is NOT the reader and
  moots nothing.

## Decisions

1. **The anchor is honestly open — not ledger lag.** All 6 children verified genuinely done
   (every cited PR merged, files at HEAD). w1 done; w2's literal floor (four named types
   render natively) done; w3 never happened (gp-w3 pivoted to the email route). Why: two
   independent audit reports converged with PR/file evidence.
2. **Wave 5 stays inside the anchor's named types.** The proven slate-2 delta on
   stat/stats/heatmap/chart — heatmap calendar/marginals/values silently ignored
   (byte-identical to plain grid), stat denom silently dropped, chart ticks uncompacted —
   IS anchor scope ("slate parity" on the very types w2 names, at the bar the TUI later
   raised). Why: executed-render proof (mix run --no-start) established the exact delta.
3. **gauge-list and dashboard are NOT built under gui-premium.** The anchor never names
   them; slate-2's charter D22 explicitly ACCEPTED the web fallback box as a conscious
   divergence; `tr-agg-resolver-wave` (under pdrender-block-parity) already carries the
   compose-clause criteria plus their resolver plumbing. No reparent, no split — the ledger
   stays un-forked. Why: "never invent scope the anchor doesn't name" is the wish's own
   hard law, and the standing D22 decision deserves a deliberate override, not a smuggled one.
4. **Chart series: web keeps up-to-4 series; no cap-down to Go's 2.** `maxChartSeries = 2`
   is a terminal-legibility ceiling in the TUI renderer, not a block contract; the web's
   s0..s3 palette shipped in gp-w1 and reducing a live surface buys nothing. Documented
   per-surface ceiling difference (TUI 2, web 4). Why: "parity" must not mean regression.
5. **Article path only; email variants untouched this wave.** New branches live in the
   `:article` emitters (`stat_html`, `heatmap_html`, chart `tick/1`); `*_email_html` stays
   byte-identical. Why: the email fleet is DONE and gate-locked; reader visuals are the wish.
6. **Dual-encode on the web = quantile bins driving two channels.** Port
   `HeatQuantileBins` semantics (heatmap.go:318, @canonical heat-quantile-bin) to Elixir;
   the bin index drives BOTH the color step AND a second non-color channel (exact values
   when `values:true`; otherwise a bin-keyed visible pattern/marker via CSS). Why: today's
   `--i`/color-mix mechanism is single-channel — copying it into calendar mode would ship
   a color-only accessibility regression against the ratified TUI law.
7. **w3 "reader chrome polish pass" is scoped to what is provably chrome and provably
   unowned:** an `@media print` block for the bulldocs reader (Sheets sibling has one at
   sheets.html.heex:262-277; bulldocs has zero; no issue/task anywhere owns it) plus
   styling `.bp-unknown-block` (zero CSS rules today — an unstyled bare div) plus two
   stale-comment fixes. Typography is OWNED by `au-w5-reading-typography` (open,
   human-gated) and the W3.8-family theme-bridge task — gui-premium does not touch type.
   Mobile-column padding is unverified roughness → backlog, not this wave. Why: the
   anchor's literal w3 is five words; print is the least-invented reading with a concrete
   in-repo precedent.
8. **The showcase must be AUTHORED, then proven.** It currently contains zero slate-2-mode
   blocks (91-block histogram verified live) — the gap is an absence. A dedicated dogfood
   slice adds the new-mode blocks and proves the live render on web AND TUI, sequenced
   after the render slice deploys. Why: the anchor names the showcase as the acceptance
   surface; unrendered code is not a finished experience.
9. **Ledger broadening, stamped explicitly:** table typed-cols (num/delta/spark) and
   roadmap-v2 render enrichment are real, proven, snapshot-authoritative web fidelity gaps
   on types the anchor does not name in w2. As epic lead I ratify them as gui-premium
   BACKLOG under the epic's own title ("reader visuals at TUI quality") — filed now,
   built in a later wave, never silently. gauge-list/dashboard remain excluded (D3).
10. **Ledger hygiene:** gp-w3b-email-popup and email-prose-polish (done, work verified
    real) lacked acceptance_criteria arrays — retroactive criteria with PR evidence are
    stamped this wave so the done-ledger is auditable. Why: three real-done-left-unreadable
    incidents today; the ledger is the spine.
11. **Marginal Σ sums render as NUMBERS on the web in both flag combinations** (the TUI
    shows pure-shade bars when `values:false` — a 1-char-column constraint the browser
    lacks). Ratified; code-anchored at data_viz.ex:255-261 + heatmap.go:543. Why: the sums
    ARE the marginal's point wherever width permits.
12. **Printed calendar heatmaps clip weeks beyond the page width.** A scroll container
    can't scroll on paper; `break-inside: avoid` keeps what fits whole. Ratified — standard
    paged-media tradeoff (charter-prose anchor only; no code comment exists or is needed).
13. **Paper bodies are written ONLY via `bp bulldocs patch` with `ifRev` in the request
    BODY.** The CLI `--if-rev` flag is a proven silent no-op (sends a query param; the
    controller reads body `ifRev`), and generic `bp doc patch`//v1/data/mutate never
    refreshes the `body_html` cache the reader serves — a "successful" write changes
    nothing visible. Why: rehearsed end-to-end on a scratch paper against guerrilla
    (append preserved 3→7 blocks; stale ifRev → 412/exit 6).
14. **The dogfood gate is article-scoped with positive-presence markers.** Whole-page
    greps are unpassable by construction (the inline stylesheet's selectors + doc-comment
    contribute Unsupported=1 / bp-unknown-block=2 on a perfectly clean page); the API form
    must read `.result.body.html` — the brief's literal `.body.html` is null, a vacuous
    green. Negatives ==0 (bp-unknown-block, "Unsupported block:"), positives >=1
    (bp-heat--cal, bp-heat__sum, bp-stat__denom) + a compact-tick token (lowercase k
    included). Why: both forms proven live, 0/0/0 today, flip on real content only.
15. **The dogfood chart ships exactly 2 series.** D4's per-surface ceiling stands (TUI 2,
    web 4); a fidelity exhibit must show the SAME picture on both surfaces, and 3 series
    would deliberately diverge. `gp-b-web-chart-series-cap` (backlog) enforces/documents
    the web's OWN ceiling at the code site so audits stop re-deriving D4 as a bug —
    a verifier did exactly that this wave. Why: nothing at chart_html says the divergence
    is chosen.
16. **This file is the gui-premium charter — never `bp-cloud-epic-charter.md`.** That
    rotating slot currently holds a different live epic (p-quality-gate) mid-edit; the
    dogfood task's old pointer there was stale and has been corrected. Why: writing there
    would clobber another epic's memory.
17. **The anchor's acceptance criteria are seeded BEFORE its first claim.** Seeding after
    a claim changes the work-field digest and trips `doc_changed_since_claim` — and a
    same-worker re-claim keeps the digest, so renewal cannot clear a self-inflicted fence.
    Escape hatch if fenced anyway: fresh-read the published rev + current epoch and pass
    `--set observed_rev=<rev>` in the same close call. Why: full choreography rehearsed
    on scratch tasks 2026-07-10; the documented seed-after-claim order 409s.

## Roadmap

- **W5-S1 (large, fable)** `gp-w5-dataviz-fidelity` — heatmap calendar/marginals/values
  (quantile dual-encode), stat denom, chart compact ticks; :article only; additive;
  data_viz.ex + paper-surface.css + data_viz_test.exs. The spine of the wave.
- **W5-S2 (medium, opus)** `gp-w5-reader-chrome` — @media print for bulldocs reader,
  honest `.bp-unknown-block` box, stale-comment hygiene. The anchor's w3, scoped honestly.
- **W5-S3 (small, opus)** `gp-w5-showcase-dogfood` — author the new-mode blocks into
  /papers/portabledoc-showcase, prove live web + TUI render. AFTER S1 merges + deploys.
- **Backlog (filed, unbuilt):** `gp-b-table-typed-cols` (p2), `gp-b-roadmap-v2-render`
  (p2 — render side only; resolver fields stay with tr-agg-resolver-wave crit 4),
  `gp-b-mobile-reading-column` (p3 — verify first).
- **Excluded by decision (owned elsewhere):** gauge-list + dashboard compose clauses and
  all resolver plumbing → `tr-agg-resolver-wave`; editor live-preview for dataviz →
  `tr-preview-dataviz-editor-parity`; reading-body typography → `au-w5-reading-typography`.
- **Epic close condition:** after W5 lands and the showcase proof is stamped, the anchor's
  three clauses all carry evidence — close gui-premium with the showcase as the exhibit.

## Wave log

### Wave 2026-07-10 — W5, 2 of 3 slices green, S3 honestly stalled on sequencing

**Landed (integrate these branches):**

- **S1 `gp-w5-dataviz-fidelity`** → `loop-epic/w5-s1-slate-2-fidelity-for-the-anchor-na-0-r`
  (review-fixed). Calendar/marginal/value heatmaps + stat denominators + compact chart
  ticks, all additive branches of the ONE :article emitter set; quantile_bins/1 verified
  line-for-line against Go HeatQuantileBins (nearest-rank, nonzero-only, zero→-1) and
  tick_compact/1 against formatTickCompact (10k threshold, .0 trim, sign carried). Legacy
  heatmap pinned byte-identical as a full literal string; email_golden byte-identical;
  479/0 + emit + mirror green. Review browser-eyeballed the markup against the real
  stylesheet (static harness — the eyeball the builder honestly flagged as missing) and
  FIXED one real defect: `--cal`'s display:block let the grid's `auto` label track absorb
  all free space — the whole calendar sat right-shoved behind a giant dead gutter. Fix:
  `width: max-content` on the calendar grid (scroll container verified still scrollable
  at 420px). Everything else eyeballed clean: dual-encode markers read, matrix Σ +
  underline-strip value cells read, denom suffix reads, ticks compact.
- **S2 `gp-w5-reader-chrome`** → `loop-epic/w5-s2-reader-chrome-polish-print-stylesh-1`
  (no review fixes needed — as built). @media print for the bulldocs reader (white paper,
  chrome hidden, column expanded, break-inside:avoid on figures/dataviz), honest
  `.bp-unknown-block` dashed degrade box (eyeballed in-browser — reads exactly like
  `.bp-dataviz--empty`), two stale comments fixed (serif IS self-hosted since #1984; the
  TUI toggle is the real pdrender WASM). Review verified the print reset actually WINS:
  the themed high-specificity rules only set CSS variables, the reader never stamps
  `data-theme`, and print resolves light-scheme — the plain `background` declarations at
  the end of the sheet beat everything they must. 467/0 + greps + emit + mirror green.

**Stalled honestly:** S3 `gp-w5-showcase-dogfood` is SEQUENCED behind S1's merge+deploy;
the builder verified the markers don't exist on main/guerrilla, stopped without polluting
the production showcase, stamped a stall_note, left the task claimed in_progress with all
4 criteria open. Correct behavior, zero fabrication.

**Merge notes (lead):** both slices are api/** → auto-deploy on merge; both .ex/.heex/css
→ WAIT for the Elixir Test CI gate. paper-surface.css edits are in disjoint regions
(S1 dataviz slate section, S2 end-of-file + the :53 font comment) — any merge order is
clean. Lead closes the merge-gated criterion on each task on merge (S1 crit 5, S2 crit 4).
This charter file is committed on the S1 `-r` branch (it was an untracked working-copy
file); the shared checkout still holds an identical-minus-wave-log untracked copy at the
same path — remove or overwrite it before pulling the merge. Two judgment calls to
ratify: (1) marginal Σ sums render as NUMBERS in both flag combinations on the web (the
TUI shows pure-shade bars when values:false — a 1-char-column constraint the browser
lacks; documented in code); (2) printed calendar heatmaps clip weeks beyond the page
width (a scroll container can't scroll on paper) — standard paged-media tradeoff,
break-inside:avoid keeps what fits whole.

**Next wave:** merge S1+S2, wait for guerrilla auto-deploy, then re-claim
`gp-w5-showcase-dogfood` (same-worker re-claim per its stall_note) — author the slate-2
blocks into /papers/portabledoc-showcase and prove web + TUI live render; its gate is
already written. That completes the anchor's w2 fidelity evidence; then the epic-close
condition (charter §Epic close) is in reach: stamp the showcase exhibit onto the anchor's
three clauses and close gui-premium. Backlog beyond the close: gp-b-table-typed-cols /
gp-b-roadmap-v2-render (p2), gp-b-mobile-reading-column (p3 — the 420px page-level
overflow the review measured comes from the pre-existing `.bp-stats` auto-fit grid, a
concrete starting point).

### Wave 2026-07-10 — finish wave (Decide): dogfood re-scoped, close choreography set, 2 slices cut

Seven verification probes ran before this Decide; every load-bearing recipe is now
rehearsed, not theorized. What they established (full detail in the wave Paper
`gui-premium-wave-2026-07-10`):

- **Write path proven safe** on a scratch paper: `bp bulldocs patch` append preserved all
  existing blocks and refreshed `body_html` atomically; TWO corrections found by doing —
  the CLI `--if-rev` flag is a silent no-op (ifRev goes in the BODY, D13) and web
  paragraphs need `content:[{type:text,value}]`, never `text` (renders an empty `<p>`).
  Real showcase confirmed rev 3 / 91 blocks, byte-equal blocks↔body.blocks.
- **Gate re-scoped** (D14): article-region greps are 0/0/0 today and flip only on real
  content; the task brief's literal whole-page grep and its `.body.html` jq path were both
  unpassable/vacuous and are now replaced in the task's criteria.
- **Chart divergence reconciled against D4** (D15): the v3 probe proved the web renders
  all series uncapped — but D4 already ratified the per-surface ceiling, so the dogfood
  chart ships 2 series and the backlog task documents/enforces the web's own ceiling of 4
  instead of "fixing" a ratified decision.
- **Close choreography rehearsed on scratch tasks** (D17): anchor AC seeded pre-claim
  (done by this Decide — 3 clauses, met:false), close via targeted claim + immediate
  criteria index-merge; wrong epoch → `stale_claim`; dotted array-index keys in `set`
  create silent garbage (found + cleaned a live instance on gp-w4b, whose stale
  "PR #1910 open" criterion was also fixed to cite merge 05b45064 — 5/5 now).
- **Deploy liveness confirmed**: #2273 (02cc8e3d) and #2283 (ef89faf1, hollow gate) both
  HEALTHY on guerrilla. **Residuals named honestly**: main is red on design-check Part E
  (bulldocs.html.heex 102→103, issue 2275, filed, UNRESOLVED); the reader's inline mermaid
  engine duplicates bp-paper-mermaid.js (zero drift today) — now tracked as
  `gp-b-mermaid-reader-asset-dedup` instead of living only in a code comment.
- **Both-themes procedure proven**: the reader never stamps `data-theme`; chrome-devtools
  `emulate(colorScheme)` + computed-style/matchMedia assertion is the only real lever
  (dark rgb(24,18,13)/true, light rgb(244,236,233)/false). Installed `bp` was ~100 commits
  stale — builders run `make cli-build` and use `./dist/bp` for TUI evidence.

**Wave plan (2 slices, sequenced by blocked_by):**
- **F1 (medium, fable)** `gp-w5-showcase-dogfood` — re-claim (targeted, same worker
  string), author section 9 (calendar heatmap; marginals+values heatmap; denom stat;
  2-series compact-tick chart) via the D13 write path, prove article-scoped gate both
  forms + both themes + TUI floor. PR-less: the live render is the evidence; builder
  closes on stamped evidence.
- **F2 (medium, fable)** `gp-w5-epic-close` — independently re-verify the gates, write the
  epic-close charter entry (PR trail w1 #1600/#1606 · w2 #1614 · w3 #1660/#1674/#1830 ·
  w4 #1897/#1910/#1913 · w5 #2273; residuals per above; 5 backlog children open by
  design), commit+push, then claim gui-premium and close it stamping the 3 seeded clauses.
- **Backlog filed this wave:** `gp-b-web-chart-series-cap` (p2), `gp-b-mermaid-reader-asset-dedup` (p3).

### Wave 2026-07-10 — epic close

The close condition (§Roadmap) is met and independently verified — this entry is written
by the F2 close slice (`gp-w5-epic-close`), which re-ran every gate itself rather than
inheriting F1's evidence.

**Dogfood verified live (trust-but-verify, both forms, all six checks):** F1
(`gp-w5-showcase-dogfood`, closed done 5/5) authored section 9 "Slate 2 — the fidelity
pass" into `/papers/portabledoc-showcase` via the D13 write path (ifRev in body, rehearsed
on a scratch paper; rev 3→4, 91→101 blocks, first id fd-001 intact, blocks == body.blocks).
F2's own re-run on live guerrilla: Form 1 (page curl, article slice after the last
`</style>` at line 1799) and Form 2 (`jq -r '.result.body.html'`, 49 720 bytes) both show
`bp-unknown-block`=0, `Unsupported block:`=0, `bp-heat--cal`=1, `bp-heat__sum`=1,
`bp-stat__denom`=1, five compact-tick tokens (8M · 20.5M · 33M · 45.5M ×2). Zero
wrong-shape renders remain — the pre-fix silent plain-grid bug is provably gone (D14 gate
shape). F1 additionally proved both themes machine-checkably (chrome-devtools emulate:
dark rgb(24,18,13)/matchMedia true, light flip, sane computed colors on section-9's own
denom/Σ/tick elements) and the TUI floor (fresh `./dist/bp` at 8270dd5a, 508 lines, zero
unsupported/unknown/panic/error; calendar + matrix + denom + compact ticks all present).
No render defect found on any surface — nothing new filed.

**The anchor's three clauses, evidenced (all 10 PRs verified MERGED via `gh` at close):**

- **w1 mermaid** — #1600 (evergreen mermaid theme, both schemes, re-render on flip) +
  #1606; live showcase's 4 diagrams render premium.
- **w2 slate parity** — #1614 + #2273 (slate-2 fidelity: heatmap calendar/marginals/values
  with quantile dual-encode, stat denominators, compact ticks — D2/D6) + the authored
  section-9 exhibit live on guerrilla, article-scoped gate green both forms, both themes,
  TUI render clean.
- **w3 chrome** — #1660/#1674/#1830 (paper-as-email route + mail-client view + prose
  rhythm) + w4 fleet #1897/#1910/#1913 (14/14 block families as real email components) +
  #2273 (print stylesheet for the bulldocs reader, honest `.bp-unknown-block` degrade
  box — D7/D12).

**Honest residuals at close:**

- **design-check Part E is red on main** (issue 2275, OPEN): re-checked at close —
  `gh run list --branch main --limit 3` shows the latest main push (8270dd5a, run
  29114194485) failing the "Doc budgets + anchors" job at the "Design-token drift gate
  (blocking)" step; every main push since #2273 is red on this job (29112942816,
  29112003495, 29111751326). The bulldocs.html.heex 102→103 color-literal growth is
  unresolved as of this close; the fix path is in the issue.
- **Mermaid engine duplication**: `bp-paper-mermaid.js` duplicates the reader's inline
  mermaid engine (zero drift today) — tracked as `gp-b-mermaid-reader-asset-dedup`, no
  longer only a code comment.
- **Five backlog children stay open BY DESIGN** (all verified open under `gui-premium` at
  close; they do not block it — D9): `gp-b-table-typed-cols` (p2),
  `gp-b-roadmap-v2-render` (p2), `gp-b-mobile-reading-column` (p3),
  `gp-b-web-chart-series-cap` (p2, D15), `gp-b-mermaid-reader-asset-dedup` (p3).

**Close mechanics** per D17 (seeded criteria, targeted claim + immediate index-merge close,
no post-claim work-field patches) and D13–D16 for the write path, gate shape, series count,
and charter home. Note: this commit also lands the Decide-phase charter update (D11–D17 +
the Decide wave-log entry above) verbatim — it had been left uncommitted in the shared
checkout's working copy (the exact failure mode dd399f10 later fixed for the epic-cycle
tooling), so the decisions this entry references now exist in history.

**gui-premium is closed.** Anchor `gui-premium` → done, 3/3 clauses stamped with the trail
above; the epic's board truth is the ledger, the exhibit is section 9 live.

### Wave 2026-07-10 — finish-wave REVIEW: verified, one ledger incident fixed, grade A-

**Landed:** both slices real. F1 `gp-w5-showcase-dogfood` (PR-less, done 5/5) — reviewer
re-verified everything independently: gate green both forms at occurrence level (grep -o:
bp-heat--cal=1, bp-heat__sum=11, bp-stat__denom=1, negatives 0/0), all 101 block ids
diffed (91 originals in order, fd-092..101 after fd-088, epilogue last, zero dupes), both
themes re-proven in a live browser (dark rgb(24,18,13)/light rgb(244,236,233), denom
dimmer than value in both, calendar grid at max-content), TUI floor with a fresh dist/bp
at 66364d67 (508 lines, zero defect strings). F2 `gp-w5-epic-close` — every factual claim
re-checked: 10/10 trail PRs MERGED via gh, issue 2275 OPEN, doc-gates red on 66364d67 at
the same pre-existing drift-gate step (run 29116928119 — the docs commit added no new
red), anchor done 3/3, slice gate green. No code fixes needed on either slice.

**Ledger incident (found + fixed at review):** `gp-w5-epic-close`'s published
acceptance_criteria were cross-contaminated — the builder's 19:08:38Z read-modify-write
patch used `era-w8-zero-tax-harness`'s array as its base (concurrent enterprise-auth
epic; likely shared-/tmp collision). Restored from revision history (seed 18:51:17Z +
the 19:06:37Z evidence revision), builder's genuine evidence kept at 1,2; era task
verified intact. Filed `task-11390a3b900c8a09` (p2) for the vector + hardening. Lead
note: the restore changes the work digest under the live claim — close with
`--set observed_rev=<fresh rev>` if fenced.

**Also resolved:** the shared checkout's stranded charter working copy (strict prefix of
66364d67) — discarded safely so the next pull fast-forwards clean.

**Epic CLOSED — no next wave.** Lead tail: merge this reviewer branch, close
gp-w5-epic-close criterion 3, pick up task-11390a3b900c8a09; backlog (gp-b-* ×5) open by
design; the one red the epic leaves on main is doc-gates Part E (issue 2275, pre-existing,
owned outside this epic). Debrief: Paper `gui-premium-wave-2026-07-10` rev 5.
