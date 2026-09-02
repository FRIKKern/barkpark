# Re-derivation recipes — block-registry-truth (jarl.no historiene wave, 2026-07-31)

> **SUPERSEDED 2026-09-02 — this record is CORRECT ON ITS DATE and is left standing.**
> The counts below have moved. Today's canonical numbers, their derivation commands, and the
> full exclusions ledger live in `docs/decisions/0006-canonical-block-type-count.md`; the Elixir
> count is pinned by a run-proven test in `api/test/barkpark/portable_doc/tiers_test.exs`.
> Cite that, never a number from this page.

Verifier lane: kill the "73 blokktyper" number before any figure ships it, prove the
registry count is gate-enforced, and pin the EXACT upstream data shapes the dossier
Paper would adopt (stat / stats / stat-grid / chart / bar-chart / figure), plus what the
100-block wishlist already designs for scoreboard / timeline / provenance.

All rows re-derive from a clean checkout. Elixir rows need `CC=clang` on this machine.

| # | Claim | Command |
|---|---|---|
| 1 | The tiers completeness test is GREEN: 10 tests, 0 failures — the registry count is gate-enforced (`unclassified == []` and `phantom == []` both assert, so renderable set ≡ `Tiers.known_types()`) | `cd api && CC=clang mix test test/barkpark/portable_doc/tiers_test.exs 2>&1 \| tail -4` |
| 2 | The registry is **75**, not 73: `known_types=75` = element 29 + widget 43 + section 3 | `cd api && CC=clang mix run -e 'ts = Barkpark.PortableDoc.Tiers.known_types(); IO.puts("known_types=#{length(ts)}"); for {k,v} <- Barkpark.PortableDoc.Tiers.by_tier(), do: IO.puts("#{k}=#{length(v)}")' 2>&1 \| tail -4` |
| 3 | The compose.ex dispatch surface is 75 too: 71 direct `compose_block(%{"type" => "X"` clauses + 4 guard-only types (`stats`, `stat-grid`, `tasks`, `task-list`) | `cd api && { grep -oE 'compose_block\(%\{"type" => "[A-Za-z0-9-]+"' lib/barkpark/portable_doc/render/compose.ex \| grep -oE '"[A-Za-z0-9-]+"$' \| tr -d '"'; printf 'stats\nstat-grid\ntasks\ntask-list\n'; } \| sort -u \| wc -l` |
| 4 | The "69" came from a LOWERCASE-ONLY grep that silently drops the two camelCase types `arrayOf` and `localizedText`; the extra 4 are the guard-clause types | `cd api && grep -oE '"type" => "[a-z0-9_-]+"' lib/barkpark/portable_doc/render/compose.ex \| sort -u \| wc -l` (→ 69) then compare to row 3 |
| 5 | The MUST-RUN grep `'"[a-z0-9-]+" =>'` (→ 29) counts arbitrary map KEYS, not block types — it is not a registry measurement at all | `cd api && grep -oE '"[a-z0-9-]+" =>' lib/barkpark/portable_doc/render/compose.ex \| sort -u \| wc -l` |
| 6 | The guard clauses are exactly two pairs, repeated across style arities | `cd api && grep -oE 'when t in \[[^]]+\]' lib/barkpark/portable_doc/render/compose.ex \| sort -u` |
| 7 | The test's own extractor (direct regex + `when t in [...]` regex) is the canonical definition of "renderable type" and has a parser-sanity guard (`length(types) > 30`) | `cd api && sed -n '82,133p' test/barkpark/portable_doc/tiers_test.exs` |
| 8 | Upstream `stat` shape: `{value (required, non-empty → else honest empty box), label?, max?, denom?, spark?: number[]}`; `max` draws a proportional bar, `spark` an inline `<polyline>` sparkline (viewBox 120×26) | `sed -n '99,119p' js/packages/react/src/blocks/dataviz.ts` |
| 9 | `stats` and `stat-grid` are the SAME emitter: `{items: statBlock[]}`, non-map items filtered, empty → `bp-dataviz--empty` | `sed -n '120,126p' js/packages/react/src/blocks/dataviz.ts` · `sed -n '627,636p' js/packages/react/src/blocks/dataviz.ts` |
| 10 | Upstream `chart` shape: `{series: [{label?, points: number[]}] (max 4, empty-point series dropped), kind?: "bars"\|"line" (default line), caption?, axes?: {min?, max?, xLabels?: string[]}}`; renders inline SVG viewBox 640×190 with `<text>` tick/axis labels | `sed -n '422,448p' js/packages/react/src/blocks/dataviz.ts` |
| 11 | Upstream `bar-chart` shape: `{bars: [{label, value}], max?, values?: boolean}` — horizontal proportional rows, denominator is the DATA MAX (never the sum) unless explicit `max` | `sed -n '551,584p' js/packages/react/src/blocks/dataviz.ts` |
| 12 | Upstream `figure` shape: `{child: Block, caption?}` — a single wrapped child block + `<figcaption>` with the bold "Figure N." run-in split | `sed -n '644,649p' js/packages/react/src/blocks/core.ts` |
| 13 | The chart SVG emits `<text>` elements (tick labels, x-labels) — any og-image/satori parity scope for figures must answer whether satori renders `<text>` in embedded SVG | `grep -n 'bp-chart__tick' js/packages/react/src/blocks/dataviz.ts` |
| 14 | The 100-block wishlist paper's baseline was **62** canonical types (25/35/2) on 2026-07-17 — so 62 → 75 in two weeks; the paper's own numbers are already stale | `bp paper view block-wishlist-100 \| sed -n '1,12p'` |
| 15 | The wishlist DOES design a timeline block: **B046 `chronology`** = `{events: [{date, title, content?}]}`, ":widget, cost STATIC", explicitly "hand-authored narrative, not live task spans" — UNBUILT | `bp paper view block-wishlist-100 \| grep -n -A12 'B046 chronology'` |
| 16 | The wishlist DOES design a provenance block: **B048 `citation-list`** = `{refs: [{id, title, url?, authors?, year?}]}` with inline cite markers — UNBUILT | `bp paper view block-wishlist-100 \| grep -n -A10 'B048 citation-list'` |
| 17 | Two more provenance-adjacent designs, both UNBUILT and both flagged "needs block-registration seam (plugins cannot register block types today; D10 backlog)": **B080 `commit-card`** `{repo, sha}` and **B081 `pr-status`** `{repo, pr, show?}` | `bp paper view block-wishlist-100 \| grep -n -A12 'B080 commit-card'` |
| 18 | **B100 `freshness-badge`** `{verifiedBy, verifiedAt, staleAfterDays?}` is the closest designed "kilde/dated-receipt" stamp — UNBUILT | `bp paper view block-wishlist-100 \| grep -n -A10 'B100 freshness-badge'` |
| 19 | There is NO designed scoreboard/duel block anywhere in the 100; nearest is **B011 `radar-chart`** `{axes: string[], series: [{label, values: number[]}]}` (multi-axis profile comparison) and **B049 `pros-cons`** — both UNBUILT | `bp paper view block-wishlist-100 \| grep -in 'scoreboard\|duel\|versus'` → no hits |
| 20 | Prior art proves the duel scoreboard is TODAY rendered as a plain `table`, and the stat band as shipped `stats`-with-spark — no new kind was needed to publish "32 cells, $16.54" | `bp paper view scaffy-loop-bench-status \| sed -n '20,60p'` |
| 21 | Nearest SHIPPED timeline-shaped block is `roadmap` = `{snapshot: [{title, status, left, width, phase_row?}], today?: number, scale?: string[]}` — author-supplied left/width percentages, no dates | `cd api && sed -n '590,640p' lib/barkpark/portable_doc/render/components.ex` |
| 22 | 11 of the 100 wishlist candidates have SHIPPED since 2026-07-17 (bar-chart, criteria-progress, equation, footnote, steps, tabs, expandable, video, api-endpoint, code-tabs, toc) while every block this wave wants (chronology, citation-list, radar-chart, svg-inline, freshness-badge, commit-card) is still unbuilt | rows 3 + 15–19 compared |
| 23 | The @barkpark/react registry is test-pinned at **70** keys — but that number INCLUDES ~9 named authoring-drift aliases (bulletList, bullet_list, bulleted-list, bulleted_list, numbered_list, quote, h1, h2, h3, ordered-list), so canonical JS coverage < Elixir 75. Do NOT quote 70 as a canonical-type count. | `cd js/packages/react && grep -n 'toHaveLength(70)' tests/PortableDoc.test.tsx` · `sed -n '33,39p' src/blocks/registry.ts` |
| 24 | A PRIOR independent derivation already said **Elixir 75 canonical** (mobile shell-and-cache lane, 2026-07-23), against JS 66 test-pinned — 75 is not a one-off reading | `grep -n 'Elixir 75 canonical' tooling/grip/ledger/bp-prior-art-retry-2026-07-26.md` |
