<!-- doc-tier: cold | canonical-for: legendary-paper-survey-17-evidence | budget: 1200tok -->
# Survey 17 — PDS wave 45 / Public reader

Verdict: `partial`. The public reader has coherent hierarchy and suppresses blank paragraph content, but its 390-pixel layout horizontally overflows and fixed Email/TUI controls cover prose.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; 227 blocks; JSON SHA-256 `5894db69f3d3f9ddc0416bd5e5e6b50dc72c1d962efb56ac7fd863b1a8d1caa7`.
- Outline: one H1, 23 H2, nine H3, no level skips. Repeated H2 gaps are 45.59 pixels and the hierarchy remains visually distinct.
- Density: 9,916 words and 63,394 text bytes. At 1440×900 the document is 34,184 pixels / 38 viewports; at 390×844 it is 56,482 pixels / 66.9 viewports.
- Twelve prose-heavy tables carry 119 rows. Four require internal horizontal scrolling at 1440 pixels; all 12 require it at 390 pixels.
- Narrow layout is broken: document width is 517 pixels for a 390-pixel viewport. An unbroken source path expands the 310-pixel article to 477 pixels because list prose lacks a general overflow-wrap/word-break rule.
- Fixed Email/TUI pills cover up to 101 pixels, or 32.6%, of the narrow reading column. Their fixed right/bottom placement intersects the article.
- The Paper stores 124 empty paragraph blocks, but they contribute no visible height; 103/227 top-level blocks render visible content. Structural whitespace is regular rather than a blank-content desert.
- The centered 720-pixel shell and 640-pixel article are comfortable at desktop width, but unchanged 40-pixel side padding leaves only 310 pixels at phone width.
- CDP metrics SHA-256: `524f8ee177ca9d7296476609f55a4882b48665990f638b65f84725c2f72519e0`; narrow overflow screenshot SHA-256 `368f792f8f7025b85fcad4e0617a2470295fa371c76c170c97edcea216241e0`.

Touch interaction, Safari/Firefox, non-macOS fonts, screen readers, alternate readers, and print remain unvisited. A regression must prove no page overflow, no control/article intersection, and reachable table cells at 390 pixels. No state mutation occurred.
