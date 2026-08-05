<!-- doc-tier: cold | canonical-for: legendary-paper-survey-37-evidence | budget: 1200tok -->
# Survey 37 — Cloud Console wave 28 / TUI80 structure

Verdict: `partial`. The TUI preserves the Paper's block order and width boundary, but drops every authored table header and expands the document into a 2,337-line terminal stream.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; source SHA-256 `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`.
- Source contains 237 unique ordered IDs: 43 headings, 156 paragraphs, 18 tables, 13 callouts, and seven lists. Missing, blank, and duplicate IDs are zero.
- The exact current-worktree 80-column render exits zero and produces 2,337 body lines / 190,243 bytes, maximum display width 80, and zero overflowing lines. Installed `bp paper view` produces the same body; its Related appendix adds 20 lines.
- All 18 tables store their authored header band in top-level `header`, comprising 57 cells. The TUI renderer reads `head`, `columns`, or a header-marked first row, so it omits all 57 header cells while retaining 155 body rows.
- All seven lists use supported arrays of inline items; their item order and text survive.
- The renderer intentionally suppresses all 103 empty paragraph spacer blocks. Visible nonempty blocks retain source order, but rendered output carries no per-block IDs.

Verify must add a legacy-`header` regression fixture, prove source-to-render marker coverage across all visible blocks, and assess whether empty-spacer suppression is the desired canonical policy. No state mutation occurred.
