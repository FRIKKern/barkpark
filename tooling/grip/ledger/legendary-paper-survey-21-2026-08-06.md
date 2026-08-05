<!-- doc-tier: cold | canonical-for: legendary-paper-survey-21-evidence | budget: 1200tok -->
# Survey 21 — PDS wave 45 / Studio semantic parity

Verdict: `partial`. Live Studio preserves top-level order and visible text on open, but loses legacy table headers and strong marks in the editing representation and creates accessibility friction around tables.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; 227 source blocks and 227 reconstructed blocks in exact ID order; untouched round-trip emits zero operations.
- Three legacy-header tables lose three header rows / nine cells in Studio. All 12 live tables expose zero `th` and zero accessibility-tree `columnheader` roles; nine source tables also genuinely lack header metadata.
- Eight strong-marked text nodes / 161 characters render regular-weight with no strong/b elements. A simulated one-character edit emits replacement content without the mark, proving write-loss risk.
- Nine callouts lack source tone/title/collapse fields. Studio normalizes them to generic info divs; a body edit would persist explicit info tone, null title, and false flags, losing absent-versus-explicit provenance.
- Every table is interleaved with five editing controls: 60 repeated controls around 12 unnamed tables, with no control-to-table relationship in the accessibility tree.
- The main landmark and heading/list order are correct: 33 headings, seven lists / 44 items, 12 tables / 116 rows / 389 cells. Accessibility-tree sequence SHA-256 is `2b077985d0e6957b712d26360c9ecb9a4724e90825447fe580dd3d0612801f8d`.
- Twenty-one non-prose roots—12 tables and nine callouts—omit `data-bp-id`, reducing edit-surface traceability without changing content.
- All seven lists use supported inline-text arrays; no list text loss was found.

Real VoiceOver/NVDA, keyboard traversal, other engines, zoom, actual live edits, revision races, inspector inertness, and targeted regressions remain unvisited. No state mutation occurred.
