# Epic charter — TUI Creative Slate, pass 2 (heat + meters + tokens)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The former **staging-barkpark** charter that lived here is preserved verbatim at
> `.claude/workflows/bp-staging-barkpark-charter.md` (and in git history); earlier charters
> at `bp-studio-ui-premium-charter.md` / `bp-cloud-peak-aesthetics-charter.md`.
> This file is now the memory of the **pbp-tui-slate-2** epic.

Epic bp task: `pbp-tui-slate-2` (published; child of `pdrender-block-parity`; every slice task is its child).
Predecessor `pbp-tui-creative` is CLOSED (done 2026-07-08) — it delivered the ratified slate paper `pbp-tui-creative-slate` plus the first pass (heatmap #1472, stat #1490, chart #1499) AND the aggregate-resolver arc (#1510/#1546/#1516). This epic is the SECOND slate pass.

## Vision

`bp` and the TUI reader show Claude-Code-/usage-grade dashboards — a 38-week contribution calendar, KPI stat cells with dim denominators (71/118), ▓/░ meter rows of task counts by worker/phase — and every one of them, piped through `| cat` with ANSI stripped, is still a complete readable artifact. Datum lives in geometry (░▒▓█ glyphs, aligned digits); truecolor is reinforcement only. That detail-ceiling law is machine-checked: one shared golden helper asserts strip-equality across NoColor/ANSI256/TrueColor for the data-viz family, forever.

## Decisions

- **D1 — New anchor, not adoption.** `pbp-tui-creative` is done; this epic files a NEW anchor `pbp-tui-slate-2` under the still-open `pdrender-block-parity`. *Why:* reopening a closed strategy task would falsify the ledger; its waves are all merged.
- **D2 — The aggregate resolver is NOT future work.** `agg_for_query/2` (tasks/query.ex:228) + `@dataviz_types` shapers (task_resolver.ex) are MERGED. *Why:* the wish's "resolver is wave 3, don't build it" is stale — no slice re-files it; wave blocks are snapshot-authoritative (`{query,snapshot}`, resolver deletes `query` on resolve — the shipped house pattern). Wiring `gauge` into `@dataviz_types` + `gauge_shape/1` is a future Elixir slice, out of this Go-only wave.
- **D3 — Extend-not-fork on heat.** heatmap-calendar and matrix-extras are MODES of the one canonical `heatmapRenderer`/`heatCell` family (heatmap.go). *Why:* the matrix render (rowLabels/colLabels) already ships (heatmap.go:99-164); a sibling renderer would be a decoy fork of a ratified contract. New law is additive: one quantile-bin function (4 bins) drives BOTH the glyph `░▒▓█` and `GenHeatRamp[k]` color from one index (simultaneous dual-encode). The legacy either/or `ramp:` path, `heatTrueColor` 2-endpoint interpolation, and sample_m11 goldens stay byte-untouched. Stamp `@canonical capability:heat-quantile-bin` on the bin function.
- **D4 — GenHeatRamp = 4 hand-authored literal hexes** as a `ramp` array on the EXISTING `color.pdrenderHeatmap` passthrough node. *Why:* already in PASSTHROUGH_FAMILIES (derive.mjs:944) — zero new registration; hand-authored (GitHub-style non-linear greens) because computing stops from base/peak in Go re-introduces the interpolation the passthrough family exists to avoid. Emitted verbatim by `pdrenderGo` as `[]lipgloss.Color` mirroring `GenChartSeries`; tokens.json + tokens_gen.go land in ONE commit (`node design/emit.mjs --write`); both `.ex` artifacts stay byte-stable because only `pdrenderGo` reads that node.
- **D5 — stat-grid is NOT rebuilt.** `stats`/`stat-grid` (statsRenderer) already ships with DefaultFlex-measured 2-col→1-col (stat.go:257). *Why:* filing "build stat-grid" would re-implement a registered block. The only delta: a `denom` item field → dim label / accent value / dim denominator. Zero width arithmetic; `TestNoInlineDivideFormulaOutsideSolver` stays green.
- **D6 — gauge-list count-mode buckets in Go** over the existing task-list snapshot row, dims `worker|phase|status|priority` only. *Why:* those fields are already on the wire (task_resolver.ex row_from_task); `group_by epic` is UNBACKED (no epic on the row, none in `@agg_group_dims`) — deferred to the future resolver-dim slice, never faked from `parent`.
- **D7 — The "14-renderer parity harness" does not exist.** Real invariants: the 12 cross-surface Elixir-generated goldens stay byte-unchanged (a Go wave may not regen them), the 16 milestone goldens stay byte-unchanged, and each new block adds its own milestone trio (sample_mN.json + TestGoldenMN + goldens/). *Why:* criteria phrased against a phantom harness are vacuous or force forbidden Elixir work.
- **D8 — Dim = `ctx.Theme.Dim` (foreground color), NEVER `lipgloss.Faint()`.** *Why:* the wasm reader's `applySGR` has no case for SGR 2 — Faint-dim passes every ANSI-stripped Go golden yet silently vanishes in the browser. Calendar zero cells = dim `·`, never `▁`, never blank.
- **D9 — The 3-profile golden helper drives BOTH knobs** — pdrender `ctx.Profile` AND the inverted termenv global `lipgloss.SetColorProfile` (termenv: TrueColor=0…Ascii=3; the two in-repo comments contradict — the helper's doc comment settles it). Law enforced: `ansi.Strip(out@ANSI256) == ansi.Strip(out@TrueColor) == out@NoColor` — the machine form of "datum in geometry, color as reinforcement".
- **D10 — Doctrine lives in a NEW contract doc** `docs/contracts/tui-render-doctrine.md` (fresh `canonical-for: tui-render-doctrine`; contracts are byte-unbounded). *Why:* docs/cards/tui.md is 2388/2400B (12 bytes free) and cards are hard-capped at 7 — the wish's "trim within budget" is impossible by ~48x. The card gets a ~70B trim + one-line pointer in the same PR (doc-gates trigger on `**/*.go`, so the card must be ≤2400B whenever it rides a Go PR).
- **D11 — "Renders in the WASM reader" needs a real proof.** *Why:* the wasm gate only recompiles and renders sample.json — a registered block can compile to wasm and never be exercised. Final slice extends `cmd/pdrender-wasm/smoke.mjs` to render every new block's snapshot and assert non-fallback output + dim-as-color-escape.
- **D12 — Go-only wave, worktrees mandatory** (internal/pdrender is hot concurrent-dev); merge on the Go gate (`go build/vet/test`), never waiting for Elixir Test.

### Wave-2 decisions (charts + structure)

- **D13 — heatCell goes Barkpark dual-encode, MINIMAL flavor.** Inside the `if trueColor` branch ONLY: heatmap.go:275 `Render("█")` → `Render(heatShadeGlyph(intensity))`; :287 `strings.Repeat("█", w)` → `strings.Repeat(heatShadeGlyph(intensity), w)`. `heatTrueColor` foreground and the legacy linear 6-step ladder stay untouched — NOT converged onto quantile `heatDualCell` (that flavor would churn sample_m11's NoColor shade goldens). *Why:* GitHub-solid █ would amend the strip law we ratified one wave ago; dual-encode is already the D3 house pattern; the minimal flavor is provably zero-golden-churn (every stored golden renders at NoColor, which never enters the branch). The doctrine §Known-gap (tui-render-doctrine.md:75-83) and the golden_profiles_test.go:100-104 gap comments are deleted in the SAME PR that wires the sample_m11 TRUECOLOR grid into assertStripComplete.
- **D14 — The box-curve junction slice is DROPPED — false premise.** chart.go plots every series into a shared braille union canvas (braille.go:71-82, :137); no ╰│╮ glyphs exist anywhere in the chart path and orphan fragments cannot occur. No box-drawing line-chart mode is commissioned — that would fork the braille renderer against extend-not-fork. The chart slice reframes to the two real gaps: compact-unit y-ticks and enforcing max-2-series.
- **D15 — Compact-unit y-ticks are NET-NEW; max-2-series becomes ENFORCED law.** No k/M formatter exists to reuse (stat.go consumes pre-formatted display strings). A small `formatTickCompact` lands beside `formatTick` (chart.go:415): |v| ≥ 10 000 → k/M/B, one decimal with trailing .0 trimmed (45500000 → `45.5M`); below threshold byte-identical to today so small-value chart goldens stay stable. max-2-series is aspirational today (unbounded loop chart.go:105-108, modulo color cycle :408) — the slice caps at the first 2 series with a test.
- **D16 — Table typed columns extend cell CONTENT, never width math.** tableRenderer's delegation to lipgloss/table's own auto-sizer is settled law (richblocks.go:18-25) — no Flex port, ever. Typed spec = new table attr `cols:[{type:text|num|delta|spark}]` — key is `cols`, NOT `columns` (overloaded: layout block name + layout attr). spark reuses stat.go `sparkline(values, 14)` (the one canonical primitive; braille canvas and heat ladders are decoys); delta renders ▲/▼/− from the numeric value via toFloat — glyph-encoded, color as reinforcement only; num/delta right-align via the existing (row,col) StyleFunc. `TestNoInlineDivideFormulaOutsideSolver` stays green by construction.
- **D17 — Roadmap v2 is GLYPH-LAYER ONLY; the structural projection is untouchable in a Go wave.** roadmap.golden.json is the mix-generated cross-surface parity fixture — no new structural role/lane, or the slice stops being Go-only. Everything rides existing lanes + NEW optional author attrs: ▓done/░planned derived from the existing status role; ◆ from optional row `milestone:true`; date rails from optional block `start`/`end` ISO dates + per-row dates (Go date→pct math over author-supplied literals — snapshot-authoritative; resolver enrichment stays a future wave — row_from_task doesn't even emit left/width today); month ┊ ticks placed by a NEW largest-remainder distributed-rounding helper (none exists; pctToCell's independent rounding drifts). Glyph precedence ┃>◆>note>▓>░>┊>·. The slice owns the sample_m6_w*.txt regen with rationale (status-derived ▓/░ changes existing roadmap bytes).
- **D18 — tasks layout:tree derives from the depth SEQUENCE; the parent_id framing is dropped.** parent_id is a query INPUT, never a row output — row_from_task emits only title/status/priority/worker/criteria/phase (task_resolver.ex:311-321). D6 precedent: never fake a wire dim. `depth` IS a supported literal-row field (sample_m6 uses it), so the tree renders ├─└─│ rails from the consecutive-depth structure of author rows. `layout:` is a NEW dispatch axis on taskListRenderer (only grid mode exists today). Right-aligned worker/pri meta grid; labelW clamp at depth≥3; the existing 0..5 depth clamp holds.
- **D19 — pipeline layout:flow files for WAVE 3, linear v1.** The mermaidflow/mermaidflowlr engine already gives ──▶ arrowheads, no-crossings-by-default (crossers defer to the legend), and Dim-styled wire; the delta is a ~40-80 LOC snapshot→mmGraph adapter chaining implicit node[i]→node[i+1] edges. Cheap — but wave capacity is 5 slices and finishing beats starting. DAG branching needs an edges wire field (future resolver wave; never invented from snapshot). wasm-proof stays sequenced last, after wave-2 blocks are on main and deployed.
- **D20 — Merge guard update.** #2089 is MERGED (f2df6d76). Builders cut worktrees from `origin/main` after `git fetch` — never `integrate/slate2-w1` (historical), never the stale local checkout.

## Roadmap (integration order)

| # | Slice | Task | Size | Status |
|---|-------|------|------|--------|
| 1 | Detail-ceiling doctrine contract + tui.md card pointer + shared 3-profile width-golden helper (proven on existing heatmap/stats/chart fixtures) | `pbp-slate2-doctrine-goldens` | medium | merged #2089 |
| 2 | Heat family v2: GenHeatRamp[4] tokens + quantile bin + simultaneous dual-encode + heatmap-calendar mode + matrix Σ marginals/exact values | `pbp-slate2-heat-family` | large | merged #2089 |
| 3 | gauge-list block — share/count modes, snapshot-authoritative, ▓/░ meter rows over the task-list wire contract | `pbp-slate2-gauge-list` | medium | merged #2089 |
| 4 | stat cell denom — dim label / accent value / dim denominator (71/118) | `pbp-slate2-stat-denom` | small | merged #2089 |
| 5 | heatCell truecolor dual-encode (D13 minimal flavor) + close the doctrine §Known-gap + wire m11 truecolor grid into assertStripComplete | `pbp-slate2-heatcell-dualencode` | small | merged #2100 |
| 6 | chart compact-unit y-ticks (45.5M) + max-2-series enforced (D14/D15; junction slice dropped) — trio sample_m20 | `pbp-slate2-chart-units` | small | merged #2100 |
| 7 | table typed columns `cols:[text\|num\|delta\|spark]` (D16) — trio sample_m21 | `pbp-slate2-table-typed-cols` | medium | merged #2100 |
| 8 | roadmap v2 glyph layer: date rails, month ┊, ▓done/░planned, ┃today, ◆milestones, precedence, distributed-rounding ticks (D17) — owns sample_m6_w*.txt regen; trio sample_m22 | `pbp-slate2-roadmap-v2` | large | merged #2100 |
| 9 | tasks layout:tree from the depth sequence + right-aligned meta grid (D18) — trio sample_m23 | `pbp-slate2-tasks-tree` | medium | merged #2100 |
| 10 | pipeline layout:flow linear v1 — snapshot→mmGraph adapter over mermaidflow (D19) | `pbp-slate2-pipeline-flow` | small | wave 3 built (m24) |
| 11 | WASM reader per-block proof — smoke.mjs enumerates the new blocks | `pbp-slate2-wasm-proof` | small | open — sequenced LAST; halted honestly in wave 3 (m24-m26 not on main yet) |
| 12 | (future, Elixir) `gauge` → `@dataviz_types` + `gauge_shape/1`; resolver emits depth/parent_id/dates for tree+roadmap; epic/root-ancestor agg dim; `$span` → live child queries (agg_for_query/2); plural-stats shaper | unfiled | medium | later |
| 13 | dashboard container + $span-inert (wave 3 built, m25); REMAINING: migrate the ~17 duplicated golden read/write blocks onto a shared helper (m17-m19 strip loops deduped in wave 3; the golden read/write boilerplate is still copy-pasted per milestone) | `pbp-slate2-dashboard` | medium | wave 3 built (m25) |
| 14 | heat-family closure: 53-week calendar wide-width proof (m26) + m17-m19 strip dedup + @canonical repoint to the doctrine contract | `pbp-slate2-heat-closure` | small | wave 3 built (m26) |

## Wave log

- **Wave 1 (merged 2026-07-10, PR #2089, f2df6d76):** doctrine contract + assertStripComplete helper, GenHeatRamp[4] + quantile dual-encode heat family with calendar mode + marginals (trios m17/m18/m19), gauge-list, stat denom. All four slice tasks closed done with evidence (one multi-task PR; body carries the doctrine-goldens trailer — the other three record #2089 as the shipping commit). Follow-up filed from the wave: `pbp-slate2-heatcell-dualencode` (the pre-existing truecolor heatCell violates the new strip law — tracked as the doctrine §Known-gap).
- **Wave 2 plan (2026-07-10, this entry):** charts + structure — 5 slices (rows 5-9 above), integration order heatcell → chart-units → table → roadmap-v2 → tasks-tree. taskblocks.go is shared by rows 8+9 (different functions: roadmapRenderer vs taskListRenderer) — tree merges AFTER roadmap-v2 and rebases. Milestone numbers assigned to avoid collisions: m20 chart, m21 table, m22 roadmap, m23 tree. Junction-policy sub-slice dropped as a false premise (D14). pipeline layout:flow filed for wave 3 (D19).

### Wave 2 — 2026-07-10 (charts + structure, reviewer log)

**Landed (5/5 slices green, reviewed; scratch merge of all five final branches onto origin/main
(f2df6d76) was conflict-free — full `go build/vet/test ./internal/...` green, gofmt clean).**
Merge the branches in integration order (lead closes each task's "PR merged" criterion on merge;
all five claim epochs = 1):

1. **pbp-slate2-heatcell-dualencode** → `loop-epic/heatcell-truecolor-dual-encode-d13-minim-0-r`
   (this branch; carries the charter rotation + this log). D13 minimal flavor verbatim: the two
   truecolor branches Render(heatShadeGlyph(intensity)) under the untouched heatTrueColor
   foreground; m11 truecolor grid wired into assertStripComplete; doctrine §Known-gap deleted.
   ZERO stored golden bytes moved. Reviewer mutation-probed the new subtest (solid █ reds it,
   the fix greens it) — no changes needed.
2. **pbp-slate2-chart-units** → `loop-epic/chart-y-axis-learns-compact-units-45-5m--1`
   (no reviewer changes). formatTickCompact (|v|≥10000 → k/M/B, below byte-identical to
   formatTick) + maxChartSeries=2 enforced BEFORE scaling (capped 3-series render proven
   byte-identical to the bare 2-series render). **LEAD DECISION AT MERGE:** the slice owns a
   sample_m15 golden regen — m15's chart carries THREE resolver series (open/ready/done), so the
   enforced cap drops `done` and rescales the axis. Criterion 4 honestly left met=false to
   surface this. Reviewer endorses the regen: the cap is charter law and m15 now doubles as the
   live-data proof; the alternative (exempting the fixture) leaves a law-violating render on main.
3. **pbp-slate2-table-typed-cols** → `loop-epic/table-learns-typed-columns-cols-text-num-2`
   (no reviewer changes). Optional `cols:[{type:text|num|delta|spark}]` — content-only, auto-sizer
   untouched, num/delta right-align via the existing StyleFunc, delta glyph-first ▲/▼/- with
   absolute magnitude (double-sign asserted absent), spark = the ONE stat.go sparkline(values,14).
   cols-absent proven byte-identical (every pre-existing table golden untouched). Known clip: at
   w40 the 4-col table clips the spark mid-run — same behavior as the legacy m1 table, honest.
4. **pbp-slate2-roadmap-v2** → `loop-epic/roadmap-v2-date-rails-month-scale-done-p-3-r`
   (**merge the -r branch**). Glyph layer ┃>◆>◇>▓/░>┊>· with a collision-matrix test; date rails
   through the SAME clampPct/clampBarWidth/pctToCell; distributeSegments (one running boundary —
   exact totals, ≤1 spread, unit-tested); roadmap.golden.json byte-unchanged WITHOUT regen; owns
   the sample_m6 regen (diff confined to roadmap lanes, ▓→░ for non-done). Reviewer fix
   (24a6779d): a row whose start date predates the block span had its width inflated by the
   negative raw left — width now subtracts the CLAMPED left; in-span rows byte-identical, zero
   golden churn.
5. **pbp-slate2-tasks-tree** → `loop-epic/tasks-layout-tree-rails-from-the-depth-s-4`
   (no reviewer changes). layout:{mode:"tree"} on taskListRenderer; ├─└─│ rails purely from the
   consecutive depth sequence (parent_id never read — D18/D6 held); right-aligned worker/pri meta
   grid with shared column widths; house-ellipsis label clamp. Merges cleanly after roadmap-v2
   (scratch merge proved no conflict on the shared taskblocks.go).

**Ledger state:** all five tasks in_progress, claim epoch 1, evidence stamped, ONLY the merge
criterion open (chart-units additionally holds criterion 4 open for the m15 decision above).
wasm-proof (open, epoch 2) and pipeline-flow (open, unclaimed, wave 3) untouched — honest.
No ledger fixes were needed.

**Charter rotation (this commit):** slot content replaced by this epic's charter; the outgoing
studio-ui-premium charter was already preserved at `bp-studio-ui-premium-charter.md` (newer,
wave-2 inclusive); the staging-barkpark wave-1 reviewer log that rode this slot is now appended
to `bp-staging-barkpark-charter.md` §Wave log; the slate-2 wave-1 full reviewer log lives in git
history (f2df6d76) and condensed in the Wave-1 bullet above.

**Debt / wave-3 fodder:**
- No live-terminal or wasm pixel eyeball of the new truecolor dual-encoded heat grid, the m22
  roadmap, or the m23 tree — exactly `pbp-slate2-wasm-proof`'s job; RE-LAUNCH it once this wave
  is on main and deployed (it is the sequenced-last slice, epoch 2, still honestly open).
- Month ┊ ticks are equal-width segments via distributeSegments, not calendar-day-accurate
  boundaries; the space-joined scale header is not positionally aligned under the ticks —
  both acknowledged, candidate polish if roadmap v3 ever lands date-accurate ticks.
- The m23 fixture names a "Junction crossing policy" row — a story the epic dropped (D14);
  cosmetic only, rewording would churn four goldens for nothing.
- The strip-helper dedup + @canonical doc-repoint hygiene slice from wave 1 is still unfiled.

**Wave 3 should take:** (1) re-launch `pbp-slate2-wasm-proof` after these five merge and deploy;
(2) `pbp-slate2-pipeline-flow` (filed, D19 — linear v1 over the mermaidflow engine);
(3) the wave-1 hygiene slice (inline strip-equality dedup in m17/m18/m19 tests + heat-family's
@canonical doc: repoint to the doctrine contract); (4) then the Elixir resolver wave (row 12:
gauge in @dataviz_types, depth/dates on the row wire) unlocks live data for tree + roadmap v2.

### Wave 3 — 2026-07-10 (composition + live proof, reviewer log)

**Landed (3/3 built slices green, reviewed; scratch merge of all three final branches onto
origin/main (64f40057, post-#2100) was conflict-free — combined `go build/vet/test
./internal/pdrender/...` + gofmt + docs-anchors all green).** Merge in integration order
(lead closes each task's "PR merged" criterion on merge; all three claim epochs = 1):

1. **pbp-slate2-pipeline-flow** → `loop-epic/pipeline-layout-flow-linear-v1-direct-mm-0`
   (no reviewer changes). D19/D21 verbatim: `layout:{mode:"flow"}` opt-in (flowOptIn mirrors
   gridOptIn, fires ahead of the legacy ↓ stack) + a 54-line direct mmGraph adapter
   (pipelineflow.go — one rect mmNode per node, label=title||kind||synthetic-id so a box is
   never blank, implicit head edge i→i+1, dir=LR) into renderFlowchartAuto. No mermaid text
   synthesized, no DAG invented. m24 trio: w80 golden carries ─────▶ boxes; w40 proves the
   honest TD ▼ degrade; strip law proven THROUGH the pipelineRenderer entry point; absent
   layout byte-identical (parity test). Zero pre-existing goldens moved.
2. **pbp-slate2-dashboard** → `loop-epic/dashboard-container-block-authored-tabs--1-r`
   (**merge the -r branch**; carries one reviewer fix + this log). The composition capstone:
   authored tabs (inactive Dim, active Accent+Bold) over a full-width rail with a heavy ━
   run under the active tab — geometry carries the selection (TestM25ActiveRailRune pins the
   literal rune, per the charter's anti-vacuous demand); active tab's children composed via
   DefaultFlex Measure→Deeper().WithWidth(cellW)→Fits→ArrangeGrid(2); renderer-owned height
   budget (`rows` default 22) with a dim "… N more rows" marker; $span rides INERT (fixture
   carries `query:{groupBy:"$span"}`, pdrender never reads it; agg_for_query/2 named as the
   future Elixir owner). Composition proof: m25 = 2-tab /usage cockpit (chart + heatmap +
   stat-grid w/denom + gauge-list), w80 golden = 16 rows ≤ 22×80 (TestM25CompositionFitsGolden).
   ACTIVE-TAB TONE (ratified in-code): ONE tone — Accent+Bold, NOT an inverse/filled chip
   (the manifest reserves those for pressable affordances); the ━ rail is the strip-safe
   selection datum. Reviewer fix (5c9393a4): a many-tab labels row could overflow the surface
   (the rail clamped, the labels did not) — clamped via the house truncateANSI + protective
   test TestM25ManyTabsClampToWidth, mutation-probed (reds without the fix); sample goldens
   byte-unchanged. Known, accepted: web reader draws its unknown-block fallback for
   `dashboard` until an Elixir compose case lands (gauge-list precedent, charter-D12).
3. **pbp-slate2-heat-closure** → `loop-epic/heat-family-closure-53-week-calendar-pro-2`
   (no reviewer changes). ZERO renderer code: m26 = 53-week calendar (53 week-cols × 7 rows ×
   53 month colLabels) proving the wider-than-80 path — w120 renders all 53 weeks (Jan AND Dec
   in the header, widest line ≥110), w40 drops the oldest weeks (Jan gone, Dec kept);
   m17/m18/m19 tests deduped onto the shared assertStripComplete (coverage EXPANDED: m18/m19
   strip parity was w80-only, now all four widths); @canonical heat-quantile-bin doc: repointed
   to docs/contracts/tui-render-doctrine.md (docs-anchors §8 green); 38-week prose reworded to
   "80-col budget point, not a ceiling". Every m17-m19 golden byte-file untouched — the passing
   goldens ARE the byte-equality proof of the test refactor.

**Stalled honestly:** `pbp-slate2-wasm-proof` (epoch 3, in_progress, blocker_note stamped, no
commit) — the sequenced-last enumeration slice verified #2100 IS merged but m24/m25/m26 fixtures
are absent from origin/main, so it halted per the wave-1 precedent instead of green-washing a
partial enumeration. RE-LAUNCH it once this wave merges and deploys.

**Wish item (4) resolved:** the 53-week widening was confirmed cheap and BUILT this wave
(heatRenderCalendar was already width+data-driven; m26 is pure proof, zero renderer code) —
nothing to file forward.

**Ledger state:** three built tasks in_progress, epoch 1, evidence stamped, ONLY the merge
criterion open; wasm-proof in_progress, epoch 3, blocker_note honest, all criteria open;
wave-1/2 tasks closed done by the lead on their merges. No ledger fixes were needed.

**Debt / wave-4 fodder:**
- The per-milestone golden read/write boilerplate (renderM17Fixture/renderM24/25/26Fixture +
  the TestGoldenMN update/compare loop) is now ~10 near-identical copies — the row-13 helper
  migration is overdue and purely mechanical.
- The dashboard labels row truncates with … when tabs overflow; a scrolling/priority tab strip
  is a possible v2 if authored dashboards ever carry many tabs.
- Still no live-terminal/wasm pixel eyeball of any slate-2 block — exactly wasm-proof's job.

**Wave 4 should take:** (1) re-launch `pbp-slate2-wasm-proof` immediately after this wave
merges (its fixtures now exist; it is the LAST Go slice and closes D11); (2) the Elixir
resolver wave (row 12: gauge in @dataviz_types + gauge_shape/1, depth/dates/epic dims on the
row wire, $span → agg_for_query/2 live child queries) — that turns the m25 cockpit from a
snapshot demo into a live /usage screen and unlocks live data for tree + roadmap v2; (3) the
golden-helper dedup (row 13 remainder) as a cheap hygiene rider on whichever slice next touches
the test files. After wasm-proof + resolver, this epic is at its natural close — judge whether
a slate-3 exists or the epic task closes.

---

# Epic charter — CMUX × Barkpark bridge (epic `cmux-bridge-goal`)

> SLOT NOTE (reviewer, 2026-07-10): the slate-2 charter above is a CLOSED epic's memory
> (its wave-4 log records "epic complete"). The cmux-bridge decide phase filed and
> perfected the five slice tasks in the bp ledger (children of `cmux-bridge-goal`) but
> never rotated a charter document into this slot — the ratified decisions live in the
> slice-task briefs (e.g. "charter D4: the PANE owns the task"). This section records the
> wave log so the slot stays the epic-cycle memory; a future wave's strategist should
> rotate a full charter here (or ratify that the task briefs ARE the charter).

## Wave log

### Wave 2026-07-10 (pane-auto-owns hardening + writer, reviewer log)

**Landed (5/5 slices green, reviewed; scratch merge of all five final branches in
integration order, then origin/main (4dd25eeb) on top, was conflict-free — combined
`go build ./... && go vet ./internal/... ./cmd/... && go test` over cli+taskboard+
apiclient+cmd all green; gofmt clean apart from the two pre-existing byte-stable
generated files tokens_gen.go / chrome_gen.go).** Merge in this order (the lead closes
each task's "PR merged" criterion on merge; all five claim epochs = 1):

1. **cb-hook-failsafe** → `loop-epic/complete-the-cardinal-fail-safe-proof-st-0`
   (no reviewer changes). Test-only; product code provably untouched. The Stop-path
   failure matrix (fault-injecting newHookMatrixServer: dead server, 409 /claim = no
   theft, 409 /close = attempted+survived, fresh-rev 500 → plain-close fallback with
   empty observed_rev, hung server <1s) + PreToolUse dead/hung + oversized-stdin rows;
   every row asserts exit 0 AND empty stdout with a structural anti-vacuous probe.
   Source guard TestHookSourceNeverExitsOrWritesStdout bans os.Exit(/fmt.Print/os.Stdout
   /builtin print* in cmux_hook.go — reviewer re-probed the mutation (os.Exit reds it).
2. **cb-worker-id-unify** → `loop-epic/one-worker-id-honored-everywhere-the-int-1`
   (no reviewer changes). The self-fence fix: board claim 'c'/close 'x' (program.go)
   and the desk TUI workerIdentity() now derive via taskboard.CmuxWorkerID(); after
   this, ResolveWorker()'s only non-test caller is CmuxWorkerID tier-4 — the unification
   is total. Protective tests pin the fence-prone combination (CMUX_SURFACE_ID set,
   BARKPARK_WORKER_ID unset; reviewer re-probed: reverting a site reds them) and
   regression-pin tui-<hostname> outside cmux. SEMANTIC CHANGE (ratified "the pane owns
   the task"): a human on the interactive board inside a cmux pane now claims as
   cmux-<surface>, not tui-<host>.
3. **cb-shellline-tripwire** → `loop-epic/the-shell-line-can-never-drift-from-cmux-2-r`
   (**merge the -r branch**; one reviewer fix). One exported source of truth
   (CmuxWorkerPrefix / CmuxSurfaceExport / CmuxShellLine() in taskboard/cmux.go) feeds
   tier-2/3, the install shell-line, and the help echoes; the tripwire PARSES the
   emitted export line and equates it with CmuxWorkerID() — never re-pins the literal.
   Reviewer fix (828b1f39): the last residual hardcoded `cmux-$CMUX_SURFACE_ID` echo in
   `bp cmux` help (cmux_cmd.go, an echo site the brief listed) now derives from the
   constant, and the pre-existing truncated help sentence ("overridable by" dangling
   into the BARKPARK_TASK line) is repaired. Zero drift literals remain repo-wide.
4. **cb-hook-breadcrumb** → `loop-epic/a-dead-bridge-is-diagnosable-in-one-comm-3-r`
   (**merge the -r branch**; carries two reviewer commits + this log). Fail-safe is no
   longer fail-invisible: every swallowed hook failure drops a lasterr-<sha1(worker)>
   .json breadcrumb beside the renew stamp (best-effort, panic-guarded, never stdout/
   exit-code); healthy claim/renew/close CLEARS it, so presence = "the most recent hook
   action failed". `bp cmux status` surfaces it (text + last_error in -o json), splits
   task-not-found from server-unreachable via the new apiclient.GetPerspectiveResult
   (additive; GetPerspective delegates, behaviour-identical), and replaces the
   post-mortem expired_at countdown with honest ts_iso age + ~remaining from
   BARKPARK_TASK_LEASE_TTL_SECONDS (default 2700s, marked approximate); the false 300s
   TTL comments are fixed. Reviewer fix (f77f3012): the top-level recover is armed
   BEFORE any derivation, so no statement in the hook entrypoint runs unrecovered.
   Reviewer merge (a1966226): pre-resolved the wave's ONLY textual conflict
   (cmux_cmd_test.go — slice 3's tripwire tests inserted where this slice rewrote the
   adjacent status-test comment; both kept) by merging the slice-3 -r branch in, so the
   lead's integration is conflict-free in the order above. NOTE for the lead: this
   slice touches internal/apiclient/client.go (outside its FILES list, justified — the
   status code lives only in apiclient; additive, all apiclient tests green).
5. **cb-install-merge** → `loop-epic/bp-cmux-install-merge-the-additive-setti-4`
   (no reviewer changes). `bp cmux install --merge [--yes]`: additive settings.json
   writer — unknown top-level keys carried as RawMessage, foreign hooks never removed/
   reordered, dedup by exact command string, LCS line diff + --yes gate, timestamped
   .bak before overwrite, byte-identical second run reported as a no-op, malformed JSON
   → print-only fallback exit 0, missing file = first-install create. 8 tests incl.
   foreign-hook preservation, idempotency, manual-paste dedup, and a HOME-seamed
   dispatch test (never touches a real ~/.claude). Known, accepted: MarshalIndent
   normalizes formatting of foreign keys' surroundings on first run (values byte-
   preserved) and backups use 0o644 rather than mirroring the original mode.

**On merge of cb-hook-breadcrumb the lead also completes `cb-status-verb`:** its open
criterion 1 (server-unreachable degradation line asserted) is proven by
TestCmuxStatusServerUnreachable — flip it met with that evidence and close the task.

**Ledger state:** five wave tasks in_progress, epoch 1, evidence stamped, ONLY the
merge criterion open — honest, no fixes needed. Siblings cb-worker-id /
cb-hook-entrypoint / cb-install-print / cb-dispatch-verb were evidence-closed by the
decide phase as shipped-at-HEAD (bridge v1 c34774d5) — verified honest. cb-docs-card
(0/3) and cb-next-frontier-claim (design-only) untouched, correctly open.

**Debt / next-wave fodder:**
- NO live-terminal E2E of the full round-trip (real cmux pane: hook claims →
  board close as the same worker → no 409; install --merge diff against a real
  ~/.claude/settings.json) — every slice is unit-tested only, all builders flagged it.
- GetPerspectiveResult reports 401/403 as "server unreachable" — conservative but a
  wrong-token pane reads as a dead server; a future auth-aware outcome would help.
- The breadcrumb is current-health only (cleared on recovery) — intermittent failures
  leave no history beyond BP_CMUX_DEBUG stderr; acknowledged tradeoff.
- The charter slot rotation for this epic is still owed (see SLOT NOTE).

**Next wave should take:** (1) `cb-docs-card` — the bridge is now feature-complete
enough to document (CLI card anchors + a short runbook: install --merge, status,
breadcrumb diagnosis, the pane-owns-the-task semantic); (2) the live-terminal E2E
witness above, as a criterion-bearing task; (3) judge `cb-next-frontier-claim`
(design-only, claim-before-spawn dispatch) — adopt or park; then the epic anchor
`cmux-bridge-goal` is at its natural close.
