<!-- doc-tier: cold | canonical-for: legendary-paper-verify-02-evidence | budget: 1600tok -->
# Verify 02 — cross-reader `table.header` fidelity

Verdict: `proven`. Canonical `table.header` survives source/API/CLI JSON. Public and email preserve it through an explicit compatibility fallback. Studio and Go `pdrender` read only `head`, so Studio, TUI80, and human CLI drop every authored header cell while retaining body cells.

| Paper | Tables | header-bearing | `header` cells | `head` cells | body cells |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cloud Console wave 29 | 11 | 11 | 35 | 0 | 316 |
| Cloud Console wave 28 | 18 | 18 | 57 | 0 | 466 |
| PDS wave 45 | 12 | 3 | 9 | 0 | 389 |
| PDS wave 44 | 5 | 3 | 12 | 0 | 203 |
| Total | 46 | 35 | 113 | 0 | 1,374 |

- There are 112 nonempty header cells and 82 globally unique labels. No table uses `columns`, header-marked first rows, or all-header-cell fallbacks that could mask the defect.
- Fresh public/email DOMs for all four Papers return the exact ordered authored header text: 35/57/9/12 TH cells and 316/466/389/203 TD cells. Compose explicitly falls back from absent/empty `head` to `header`; both readers share it.
- Running production Studio `runToTiptap` against the four exact sources produces zero header nodes and all 1,374 body cells. Its converter reads only `block.head`; existing tests cover `head`, not `header`.
- Go decode retains the raw map, but `tableRenderer` reads only `head`, then alternate encodings absent from this corpus. TUI and human CLI share this renderer, so both emit zero header bands.
- Fresh width-80 human CLI artifacts are stable at 1,440/2,357/1,537/1,305 lines. Unique authored labels such as “why now” and “Gate re-run on the final state” are wholly absent; labels found elsewhere are coincidental body repetitions.
- Focused Go table tests pass but contain no top-level `header` regression.

Facts: source/API/JSON retain all 113 cells; public/email visibly preserve them; Studio/TUI/human CLI lose them deterministically; every body cell survives. This is reader compatibility loss, not absent source content. Carried risks: public/email still erase data-table accessibility through presentation roles; exact Studio browser driving was not repeated for every Paper; split-pane width cannot restore already discarded data. Repair must add dual-vocabulary compatibility and assert 113 headers plus 1,374 unchanged body cells. Checked all pinned sources and deployed public/email routes, Compose/render/email code, Studio converter/tests, Go decoder/renderer/tests, TUI/CLI entry points, and relevant Survey ledgers. No mutation occurred.
