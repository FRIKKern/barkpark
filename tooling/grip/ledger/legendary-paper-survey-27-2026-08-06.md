<!-- doc-tier: cold | canonical-for: legendary-paper-survey-27-evidence | budget: 1200tok -->
# Survey 27 — PDS wave 45 / Email semantic parity

Verdict: `partial`. Email preserves all non-empty text and reading order, but authored table, strong-emphasis, and callout semantics are reduced or contradicted for non-visual readers.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; 227 blocks; production email 200 / 119,290 bytes.
- All 103 non-empty blocks appear as exact normalized text in source order; 124 empty paragraphs are deliberately suppressed.
- Exact title appears in `title` and the authored H1. Seven source lists become seven semantic unordered lists / 44 items in exact order.
- All 12 tables retain visible content with nine `th` and 389 `td` cells, but every table has `role="presentation"`, actively suppressing data-table semantics.
- Eight strong-marked runs remain visually bold spans, but email contains zero semantic `strong` elements.
- Nine callouts retain styled text/order but render as ordinary divs without aside, blockquote, note role, or accessible label.
- The Paper contains no authored links, so link preservation is unexercised. Production email also has zero anchors.
- The root HTML has no language attribute. Existing audits check meaningful body and links, not heading order, table roles, mark semantics, or callout roles; the byte golden characterizes current defects.

Accessibility-tree and real screen-reader behavior, link-bearing fixtures, full task corpus search, and tests remain unvisited. No state mutation occurred.
