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
