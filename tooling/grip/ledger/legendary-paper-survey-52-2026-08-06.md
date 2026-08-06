<!-- doc-tier: cold | canonical-for: legendary-paper-survey-52-evidence | budget: 1200tok -->
# Survey 52 — PDS wave 44 / TUI80 structure

Verdict: `partial`. The direct width-80 renderer is deterministic, ordered, and bounded, but silently drops 12 authored table-header cells because it reads `head` rather than the Paper's `header` dialect.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; document SHA-256 `2c0b65b64ad255a7645a94dd9ad2fed3b38d54bb93709b28efc52011fdfb6d6b`; canonical blocks SHA-256 `a89dd730f1697b0ce25b86ace3f88d790ef6b13e24e5519d58b3ded2c09445cd`.
- Three width-80 runs produced identical SHA-256 `b89f0787a79e19b3ab5e916259e5c783d1a3ed2a1cce9d4468d8b9fbe56fe5c9`: 1,285 lines, 110,831 bytes, maximum 80 display cells, zero overflow.
- Source has 99 unique blocks: 32 headings (1/24/7), 48 paragraphs including 15 empty, ten unordered lists/85 items, four callouts, and five tables. The renderer emits 84 ordered groups; exactly the 15 empty paragraphs compact away.
- Decode retains source map, IDs, types, and order. `RenderDoc` iterates sequentially, headings remain differentiated in styled output, lists retain bullet/item order, and all callouts retain a left-bar carrier with default info tone.
- Confirmed loss: blocks `b42`, `b66`, and `dbf8` store 4+3+5 header cells under `header`. `richblocks.go` reads only `head`, `columns`, or a header-marked first row. All 12 headers are absent. Headerless `b117`/`b133` remain body-only as authored.
- Five table bodies remain, but exact flattened parity for all 203 body cells was not proven because wrapped columns interleave source-linear text. Six-column `b133` is bounded yet vertically letter-wraps values and is not comfortably readable.
- IDs/types remain internal and lack visible terminal markers. Published task searches for `pds-wave-44` returned zero.

Fresh `go test -count=1 ./internal/pdrender` passed. Checked the exact Paper, dump script/command, decoder, renderer dispatch, block/table renderers, width tests, and table fixtures. Existing tests cover `head`, `columns`, and wrapped header rows but not live top-level `header`. Verify must add that regression, prove every header/body cell structurally, decide the two headerless tables, and establish a readable narrow-table fallback. No state mutation occurred.
