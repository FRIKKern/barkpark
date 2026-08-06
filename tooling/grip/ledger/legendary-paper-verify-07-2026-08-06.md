<!-- doc-tier: cold | canonical-for: legendary-paper-verify-07-evidence | budget: 1600tok -->
# Verify 07 — Studio projection and round-trip fidelity

Verdict: `refuted`. Studio preserves all top-level block IDs and exact order on untouched load, but its source→TipTap→serialization projection changes 143 of 815 blocks and cannot safely round-trip canonical table headers, stored marks, nested lists, or absent callout tones.

| Paper | Blocks | Changed on reconstruction | Header cells lost | Marks lost |
| --- | ---: | ---: | ---: | ---: |
| Cloud Console wave 29 | 252 | 60 | 35/35 | 313/313 |
| PDS wave 45 | 227 | 26 | 9/9 | 8/8 |
| Cloud Console wave 28 | 237 | 40 | 57/57 | 67/67 |
| PDS wave 44 | 99 | 17 | 12/12 | none authored |

- All 815 blocks retain exact top-level ID/order, and each Paper emits zero untouched operations. Untouched viewing therefore does not persist the lossy reconstruction.
- Thirty-five legacy-`header` tables containing 113 cells project to zero Studio header cells.
- All 388 stored marks—380 string-form and eight map-form, covering 10,394 characters across 78 blocks—project to zero TipTap marks. Editing an affected paragraph emits a mark-free `patch-block`.
- Wave 29 nested lists `w29D015` and `w29D022` lose 1,431 and 837 source characters respectively, producing eleven additional empty list paragraphs. Editing either lossy block can persist the empty replacement.
- Editing an absent-tone callout emits explicit `tone: info` in all three affected Papers. Existing explicit tones survive serialization, although unsupported `warn` paints with the info class.
- Editing a legacy-header table emits `{rows, head: []}`. Server shallow merge retains the old `header`, creating a dual-key ghost state; downstream normalization may later fall back from empty `head` to stale `header`.

Exact source/projection/reconstruction ID-order hashes match per Paper: wave 29 `41c443456e6784b894d760477d7b747316e6e6128ab4a515edbcdddb6f15aec2`; PDS 45 `b12d92a0dc8af7aa2c2515e886037bcedcc57358333bcc0a73bf63a48108be80`; wave 28 `be5a2d3da673277ccc993cd38ac7afcf4499a43c4593129fcacfac105ac6d8ef`; PDS 44 `a8adf7045065c6444a270ca01dd376ffb56df463eeff02f631b3ae5facd2904f`.

Causation is direct: `convert.js` ignores `text.marks` and treats nested paragraph list items as inline arrays; `run-convert.js` reads only `block.head` and serializes explicit `head`; `patch.ex` shallow-merges both table keys; `callout-node.js` paints unsupported tones as info. The canonical-`head` unit test passes but has no legacy-`header` fixture. DOM parity could not run because `@tiptap/core` is absent in this worktree; pure production projection and serialization provided the decisive proof.

No file, task, or Paper mutation occurred. The safe Build must normalize supported header keys, both stored mark encodings, nested list-item shapes, and legacy table keys before claiming content-safe round trips.
