<!-- doc-tier: cold | canonical-for: legendary-paper-survey-18-evidence | budget: 1200tok -->
# Survey 18 — PDS wave 45 / Public semantic parity

Verdict: `partial`. The public reader preserves all authored visible text and top-level order, but suppresses data-table semantics and reduces callouts and strong emphasis to visual styling.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; 227 blocks; canonical block-array SHA-256 `f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da`.
- Public DOM has exactly 227 unique block wrappers in exact source order. A 517-leaf audit found zero missing or reordered semantic leaves; source/DOM normalized text share SHA-256 `89a9957a7385364c8f192df2594f1be0877018ef488d7f1ebf3e73ffb9fbcc45`.
- Heading semantics survive exactly: one H1, 23 H2, nine H3, no level jumps. Seven unordered lists render as seven `ul` elements with 45 list items.
- All 12 authored data tables render with `role="presentation"`. Three legacy-header tables retain nine `th` cells, but their parent tables are still presentational.
- Nine source tables have no `head` or `header`; their 33 visibly header-like first-row cells render as ordinary `td`. That is a source defect, while presentational roles on all 12 are reader-caused.
- Nine callouts render as generic divs with no role, label, heading, or aside grouping. Text survives, but callout meaning is visual-only.
- Eight strong-marked nodes / 161 characters render as bold-styled spans, with no `strong` or `b` elements. Visual emphasis survives; semantic importance does not.
- The HTML article reports `data-rev="0"` and no Paper ETag/revision header, while `/source` reports the pinned revision. HTML cannot independently prove its immutable source revision.
- Exactly 124 empty paragraph scaffolds remain source/DOM positions without visible text; they are noise, not text loss.

Browser accessibility trees, VoiceOver/NVDA, callout announcements, atomic revision-bound captures, phone layout, Studio, TUI, email, and release-gated historical readers remain unvisited. Tests were inspected but not executed. No state mutation occurred.
