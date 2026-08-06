<!-- doc-tier: cold | canonical-for: legendary-paper-survey-53-evidence | budget: 1200tok -->
# Survey 53 — PDS wave 44 / TUI80 reader

Verdict: `partial`. The actual 80-column TUI is horizontally safe and complete, but leaves only 48 columns for a 2,123-line Paper, loses all 12 table headers, and provides no progress, outline, current section, or search.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; 99 blocks, 32 headings (1/24/7), 48 paragraphs, ten lists, five tables, and four callouts.
- Real `computeLayout` geometry plus the production renderer: terminal 80 retains a list pane and gives Paper 48 columns/2,123 lines; 60 gives 28/4,091; 50 collapses to Paper-only and paradoxically restores 48/2,123; 40 gives 38/2,800; 30 gives 28/4,091; 20 gives 18/6,726; 16 gives 14/9,273. Every sample has zero overflow.
- At 80×24, the content viewport is 20 rows and the Paper spans about 107 screens. All 32 headings remain present at Paper widths 48, 28, 18, and 14, but long identifiers split mid-token.
- All five tables remain bounded. The three source `header` arrays/12 cells disappear because the renderer reads only `head`. At width 18, the six-column table collapses to one/two-character cells and the five-column table reaches 716 lines; at 14, content becomes isolated initials.
- Navigation supports line, half-page, full-page Space, top/bottom, back, and help. Footer/help omit the implemented Space action. `/` is a no-op in focused Paper mode. No percentage, line count, scrollbar, current heading, section jump, or outline exists.
- Paper selection resets to top; live refresh preserves offset. `G` reaches bottom in one action, but orientation and fast paging are under-disclosed.
- The fixture has zero structured links/wikilinks/task chips/TOC blocks. Raw task IDs and PRs remain inert; no related-content rail was found.

Fresh `CC=/usr/bin/clang go test ./internal/pdrender ./cmd/barkpark` passed. Checked actual layout/view/update/help code, Paper renderer/task resolver, decoder/table logic, the exact fixture, and widths 80/60/50/40/30/20/16. Verify must decide whether 80 columns should collapse to Paper-only, remove the squeezed discontinuity, reflow narrow tables as labelled records, add progress/search/heading navigation, advertise Space, and repair `header` compatibility. No state mutation occurred.
