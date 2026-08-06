<!-- doc-tier: cold | canonical-for: legendary-paper-verify-06-evidence | budget: 1600tok -->
# Verify 06 — public source order, text parity, and revision binding

Verdict: `refuted`. The public DOM preserves exact keyed source order for all four pinned Papers and exact authored text for three. Cloud Console wave 29 silently drops 406 word tokens, and no flat public response binds itself to the pinned document revision.

| Paper | Source / DOM blocks | Order | Text parity | Public revision binding |
| --- | ---: | --- | --- | --- |
| Cloud Console wave 29 | 252 / 252 | exact | refuted: two empty rendered lists | none |
| Cloud Console wave 28 | 237 / 237 | exact | exact | none |
| PDS wave 45 | 227 / 227 | exact | exact | none |
| PDS wave 44 | 99 / 99 | exact | exact | none |

- Ordered block-ID hashes are stable: wave 29 `8943464821b46ac73b10ef923b3d0e782fed23bda4a36d28b58c7de9b3afc3c5`; wave 28 `af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff`; PDS 45 `143dac068ba4049a70450167cb2d0389619c1e26dc367639a9a2b31086d39ad7`; PDS 44 `e88adb7378b49ccfa59daec24b71762f3b75a43e5ec64b05c0f536b8a1d1767b`.
- Wave 29 blocks `w29D015` and `w29D022` render as empty lists. They lose 1,435/842 normalized characters and 256/150 regex word tokens respectively: 406 tokens total.
- Wave 29 stores list items as lists containing paragraph maps. `normalize_list_item/1` unwraps a paragraph only when the item itself is a map; the list passes unchanged. Inline fallback then treats the paragraph as an unknown inline node and returns empty text.
- Three fresh source/page reads per Paper yielded stable source, identity, ordered-ID, and extracted-text hashes. Raw HTML varied per request, so raw-byte stability is not a revision contract.
- Flat HTML and source responses expose no ETag, Last-Modified, Content-Location, Digest, or Barkpark revision header. Fake `If-None-Match` requests return 200. Article `data-rev=0` is LiveView stream state, not the document `_rev`.
- The revision-header plug applies to scoped `/w/:workspace/p/:project/papers/:slug`; plugin-mounted flat `/papers/:slug` bypasses it. Separate source and HTML reads can therefore race publication without detection.
- Both Cloud Console Papers align H1, page, social, and JSON-LD identity. PDS 45/44 have correct H1 but generic page/social/JSON-LD titles. None emits a canonical link.

The proof covered all 815 source blocks and public wrappers at their pinned revisions, repeated reads, response headers, conditional requests, and the relevant Compose, Inline, LiveView, metadata, revision-header, and router paths. Two transient wave-28 HTTP 500s recovered immediately; reliability remains a separate operational concern. Connected LiveView revision change was code-inspected but not interactively driven. No repository, task, or Paper mutation occurred.
