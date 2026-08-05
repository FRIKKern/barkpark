<!-- doc-tier: cold | canonical-for: legendary-paper-survey-38-evidence | budget: 1200tok -->
# Survey 38 — Cloud Console wave 28 / TUI80 reader

Verdict: `partial`. The terminal reader is width-safe and has usable scrolling controls, but this Paper is extremely tall, table-dominated, headerless, and lacks a numeric position indicator.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; 237 source blocks.
- Display-cell measurements report zero overflow at every width: 80 columns produces 2,337 body lines, 60 produces 3,173, 40 produces 5,180, and 20 produces 12,967.
- Table material accounts for 1,576 lines at width 80 (67.44%), 2,223 at 60 (70.06%), 3,826 at 40 (73.86%), and 10,328 at 20 (79.65%).
- All 18 source tables render bodies but lose their 57 authored header cells because source `header` is outside the renderer's accepted `head`/`columns`/row-header vocabulary.
- Source hierarchy is coherent: H1 ×1, H2 ×24, H3 ×18, with no level skips. The renderer suppresses 103 empty paragraphs and emits 133 stable blank separators at every measured width.
- The standalone reader supports line, half-page, full-page, home, and end movement, although its visible help omits the supported Space/full-page command.
- The standalone TUI starts without mouse mode and no Paper wheel handler was found. This is distinct from the taskboard detail pane, which has its own mouse-routing implementation.
- Overflow markers expose only `up/down more`; the reading footer gives no numeric position, percentage, block index, or section location.

Verify should cover interactive focus ownership, mouse-wheel support, truthful key help, progress/location affordances, and a legacy-table-header repair at 20/40/60/80 columns. No state mutation occurred.
