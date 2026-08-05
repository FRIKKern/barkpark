<!-- doc-tier: cold | canonical-for: legendary-paper-survey-08-evidence | budget: 1200tok -->
# Survey 08 — wave 29 / TUI visual behavior

Verdict: `partial`; width containment and keyboard behavior pass, but density, narrow tables, mouse focus, and progress feedback fail the product bar.

- Authority: exact published revision `18768b0a14c2eead927181c4a0e37c18`; sample is the production pdrender registry at widths 80 and 60 plus PTY ANSI256 captures.
- Width 80: 1,421 lines, maximum 80, zero overflow; 704 table lines (49.5%).
- Width 60: 1,928 lines, maximum 60, zero overflow; 1,030 table lines (53.4%). Narrowing adds 507 lines (35.7%).
- Hierarchy is visually distinct: H1 rule, green H2, strong and code styling, table rules, and callout tones all render in ANSI256.
- `found`: narrow tables preserve content but fragment paths and identifiers across cells. At a roughly 26-row viewport the Paper costs about 55–75 screens, yet the Paper branch exposes no scrollbar, progress, or location indicator.
- `partial`: 139 source empty paragraphs become 112 isolated blank separators; there are no blank deserts, but source noise remains.
- Keyboard focus/scroll is implemented: arrows/j/k, ctrl+d/u, pages, space, g/G, and back navigation.
- `not_found`: main Studio TUI mouse support. It starts Bubble Tea with `WithAltScreen()` only and has no `MouseMsg` handler, so click-to-focus and wheel scrolling are unsupported in this Paper reader.
- Targeted Paper/width/wrap/table Go tests passed. Exact target opening through the interactive first-20 search result surface was not achieved, so live key deltas on this Paper remain unclaimed.

Unvisited: widths below 60, zoom/text scaling, light/non-ANSI terminals, terminal screen readers, mouse behavior after a future implementation, and other Papers/readers. No state was mutated.
