<!-- doc-tier: cold | canonical-for: legendary-paper-verify-09-evidence | budget: 1600tok -->
# Verify 09 — Studio empty nodes, focus, save safety, and revision identity

Verdict: `refuted`. Empty top-level paragraphs themselves are non-destructive and Inspector Escape behaves correctly, but Studio has confirmed silent-loss paths, traps table-boundary keys, suppresses the main focus indicator, and does not expose or enforce the authoritative document `_rev`.

| Paper | Blocks | Empty nodes | Exact round-trip | Changed | Marks lost | Headers unseen |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Cloud Console wave 29 | 252 | 139 | 192 | 60 | 313 | 35 |
| Cloud Console wave 28 | 237 | 103 | 197 | 40 | 67 | 57 |
| PDS wave 45 | 227 | 124 | 201 | 26 | 8 | 9 |
| PDS wave 44 | 99 | 15 | 82 | 17 | 0 | 12 |
| Total | 815 | 381 | 672 | 143 | 388 | 113 |

Proven safe:

- JSON projection preserves every block ID and exact order. All 381 expected empty nodes survive.
- Untouched documents generate zero patch operations.
- Editing one empty paragraph creates exactly one patch for that block and does not delete adjacent empty nodes.
- Inspector Escape passes browser probes: ordinary Escape dismisses and restores focus; format inputs can veto; nested menus can intercept; hook destruction removes the listener.

Decisive failures:

- Studio flattens 388 mark records across 78 blocks and 10,394 marked characters on open.
- Two Wave 29 nested lists open with empty items. Editing either emits a replacement containing empty arrays and can permanently erase roughly 406 authored word tokens.
- Studio imports none of 113 legacy header cells. Body-only table saves generally retain the old server key through shallow merge, but Studio remains blind and creates ambiguous dual `header`/`head` state.
- Five noncanonical callout tones paint as info: four `warn` blocks in Wave 28 and one `note` in Wave 29.
- First-cell Shift-Tab and last-cell Tab return handled=true while causing no focus or selection movement. Keys outside a table return false.
- The main editable region removes the browser focus outline without a replacement.
- CLI reads expose each correct `_rev`; Studio derives `paper_rev` from absent `content.rev`, yielding zero, and the editable canvas does not enforce that value.

Root causes are the mark-blind inline importer, paragraph-map list items treated as inline nodes, `head`-only table import, incomplete tone vocabulary, boundary handlers that consume keys without a destination, focus-outline suppression, and use of stream `rev` rather than document `_rev`.

The 13-case focused table conversion suite passed, but it does not cover the legacy shapes. Broader editor smoke testing could not run because `@tiptap/core` and Mix dependencies are absent in this worktree. No live save was performed; the nested-list replacement payload itself proves the destructive path, while current table-header persistence remains protected only incidentally by shallow merge. No file, task, or Paper mutation occurred.
