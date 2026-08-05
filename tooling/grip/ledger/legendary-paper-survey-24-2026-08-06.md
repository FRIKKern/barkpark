<!-- doc-tier: cold | canonical-for: legendary-paper-survey-24-evidence | budget: 1200tok -->
# Survey 24 — PDS wave 45 / TUI80 semantic parity

Verdict: `partial`. TUI80 preserves populated prose, headings, lists, callouts, table body rows, and order, but drops three authored table-header bands / nine cells and exposes no revision or block identity.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; 227 unique non-empty block IDs.
- Source: 166 paragraphs—42 populated and 124 exact-empty—33 headings, 12 tables / 116 body rows / 389 body cells, nine callouts, and seven unordered lists / 44 items.
- Production renderer dump at width 80 exits 0 with 1,523 lines and zero width violations.
- All 33 headings, 44 list items, nine callout bodies, and table body rows appear in exact normalized order.
- Three blocks (`block-10`, `block-32`, `block-79`) carry top-level `header`, totaling nine cells. None of those header texts appears because Go reads `head` while Phoenix accepts `head || header`.
- Eight strong-marked source spans retain their text and route through the bold styling path, but redirected and pseudo-TTY captures did not preserve style evidence; visual emphasis remains unproven.
- Empty paragraphs emit no lines, so all 124 spacer identities/multiplicity disappear. No authored text is lost, but exact structure/rhythm is not preserved.
- Decode retains IDs, but the relevant renderers do not display block IDs, document ID, or revision. Reader identity is therefore externally proven rather than self-attesting.

Add a pinned legacy-header fixture, capture the actual Bubble Tea color frame, decide the identity contract, and rerun all 12 tables—especially the seven-column table—after repair. No state mutation occurred.
