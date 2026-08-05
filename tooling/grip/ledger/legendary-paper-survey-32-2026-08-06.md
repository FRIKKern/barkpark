<!-- doc-tier: cold | canonical-for: legendary-paper-survey-32-evidence | budget: 1200tok -->
# Survey 32 — Cloud Console wave 28 / Public reader

Verdict: `partial`. Desktop contains the Paper without page overflow, but the exact 390-pixel reader clips the headline, overflows the page by 57 pixels, requires horizontal scrolling in 17/18 tables, and lets fixed reader controls obscure prose.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; 237 blocks, 134 visible substantive wrappers, and 103 suppressed empty paragraph spacers.
- Content: about 14,483 words, one H1, 24 H2, 18 H3, 18 tables, 13 callouts, and seven lists. Heading hierarchy has zero level skips.
- At 1440×900, the document is 50,476 pixels high—56.1 viewports—with a 720-pixel shell and 640-pixel reading measure. Page-level horizontal overflow is zero; three tables internally overflow by 9, 20, and 314 pixels.
- The desktop H1 spans five lines and 175.94 pixels. Fixed Email/TUI controls remain outside the prose column. Maximum visible inter-block gap is 45.6 pixels; spacers create no blank desert.
- At exact 390×844, document height is 77,061 pixels—91.3 viewports—and page scroll width is 447 pixels, creating 57 pixels of horizontal overflow. The screenshot visibly clips the H1 and prose at the right edge.
- Mobile content measure is 310 pixels. Seventeen tables require internal horizontal scrolling; tables occupy 41,881 pixels, 54.3% of document height. The widest is 954 pixels, leaving 644 pixels initially hidden.
- The fixed Email control covers 100.77 pixels / 32.5% of the reading column; TUI covers 85.22 pixels / 27.5%. Both remain over prose near the bottom-right.
- No visible links or table-of-contents navigation exist in the body. A transient 500 occurred during repeated diagnostics and recovered on the next 200 response.
- Screenshot SHA-256 receipts: desktop `acce0eefb7e9862d430dc7a0e3bd7200598aa00a602bff4d62d7092c159b99af`; narrow `11d55c2a91eb630d54e09adc1bd94525c21b8befe7901644b0be9e6c17f1c002`.

Safari/Firefox, touch scrollbar discoverability, keyboard traversal, screen readers, themes, print, and full lower-section screenshot sampling remain unvisited. No state mutation occurred.
