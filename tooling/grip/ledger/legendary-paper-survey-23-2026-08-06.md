<!-- doc-tier: cold | canonical-for: legendary-paper-survey-23-evidence | budget: 1200tok -->
# Survey 23 — PDS wave 45 / TUI80 reader

Verdict: `partial`. The terminal reader is width-safe, navigable, and free of blank deserts, but extremely long, table-dominated, missing nine authored header cells, and devoid of location/progress feedback.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; 227 blocks; one H1, 23 H2, nine H3, no level jumps.
- Width matrix: 80 = 1,523 lines / 59 screens; 60 = 2,044 / 79; 40 = 3,241 / 125; 20 = 7,856 / 303. Zero lines overflow at every width.
- Tables occupy 58.24% of width-80 lines and 71.03% at width 20. Width containment succeeds, but relational reading fragments severely.
- The 124 empty paragraphs are suppressed; 103 visible blocks yield exactly 102 isolated one-line separators and no longer blank run.
- Three legacy-header tables contain nine cells that do not render because the TUI recognizes `head`, columns, or marked rows, not top-level `header`.
- Navigation supports line, half-page, full-page, and end jumps. The help bar omits the supported space/full-page key.
- No visible scrollbar, percentage, current/total line, section location, or other progress signal exists.
- Main TUI startup does not enable mouse mode and has no mouse-message handler, so click focus and wheel scrolling are absent.

Live PTY color, exact Bubble Tea frame allocation, interactive key deltas, terminal screen readers, copied-table intelligibility, and emulator-specific wrapping remain unvisited. No state mutation occurred.
