<!-- doc-tier: cold | canonical-for: legendary-paper-survey-16-evidence | budget: 1200tok -->
# Survey 16 — PDS wave 45 / Public structure

Verdict: `found`. The anonymous public reader preserves all 227 pinned source blocks, IDs, order, and normalized text, while also preserving 124 empty paragraph spacers that make the Paper structurally red.

- Authority: Paper `pds-wave-45-2026-08-03`, revision `b992fd8aaa028b0dab30a8da76f077fd`; canonical block-array SHA-256 `5c9e77f2af56751516862425db7abfbfadc924cb9c5e8aab770cda67e9acc673`.
- Block inventory: 166 paragraphs, 33 headings, 12 tables, nine callouts, and seven lists.
- `scripts/paper_structure.py` reports exactly 124 violations, all `empty_paragraph_spacer`, all safe-repair, zero quarantined or other malformed findings; digest `f08092328594c4dd1038c7b1366adb491f83184fe2c36a07b7bae4a134ef2d59`.
- Anonymous public GET returned 200 with exactly 227 unique `data-block-id` wrappers. Ordered source/public ID digests agree at `b12d92a0dc8af7aa2c2515e886037bcedcc57358333bcc0a73bf63a48108be80`.
- Per-block normalized visible text agrees at every position: 0/227 mismatches and shared semantic-text SHA-256 `89a9957a7385364c8f192df2594f1be0877018ef488d7f1ebf3e73ffb9fbcc45`.
- Exactly 124 wrappers are empty in both source and public HTML. The renderer intentionally emits empty HTML for empty paragraphs, so there is no transport loss but substantial DOM/source noise.
- Quality remains red: 10,147 visible words, 227 top-level blocks, 33 headings, 12 tables, missing ingress, paragraph/list overload, and 124 spacers. The quality tool checks `head`, while all 12 source tables use `header`; this requires contract reconciliation before classifying them as source-header loss.
- No task directly links this Paper through `papers[]`; the campaign task’s claimed resources are the durable target link.

Browser geometry, responsive CSS, focus, overflow, assistive technology, and direct public-page revision binding remain unvisited. Tests were inspected but not executed. No state mutation occurred.
