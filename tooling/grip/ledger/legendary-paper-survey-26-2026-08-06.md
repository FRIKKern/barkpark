<!-- doc-tier: cold | canonical-for: legendary-paper-survey-26-evidence | budget: 1200tok -->
# Survey 26 — PDS wave 45 / Email reader

Verdict: `partial`. Email hierarchy and blank-space rhythm are readable, but wide tables cause page-level overflow at desktop and severe clipping/panning at 390 pixels.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; email 119,290 bytes, SHA-256 `3e29bd380466e0db716ec4bc67a197a38206a757ebf7f5157f98da70fd39a900` across flat, dataset, and scoped routes.
- Content: 10,168 visible words, one H1, 23 H2, nine H3, 12 tables / 119 rows / 398 cells, 42 populated paragraphs, seven lists / 44 items.
- Desktop 1440×900 renders 27,546 pixels high and 1,507 pixels wide. Four tables exceed the 600-pixel content column; the seven-column table reaches 1,086.97 pixels and causes 66.97 pixels of page overflow.
- At 390×844, the card content is 318 pixels but every table exceeds it; nine cross the viewport. Document width is 1,123 pixels, producing 733 pixels of page overflow and 403 overflow candidates.
- The widest mobile table initially exposes only 354/1,086.97 pixels, about 33%; several others expose only 40–83%.
- Tables use visible overflow without a local scrolling wrapper, so readers must pan the whole page to compare columns.
- Blank-desert finding is negative: 124 empty paragraphs emit no visible element, exactly 103 substantive children render, maximum inter-block gap is 30 pixels.
- Existing reader audits and byte goldens do not test browser geometry. The same overflow class was independently found in wave-29 email.

Real Outlook/Gmail/Apple Mail, Safari/Firefox, 320 pixels, zoom, dark mode, print, touch, and screen readers remain unvisited. Any repair must obey inline-style mail constraints. No state mutation occurred.
