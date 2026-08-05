<!-- doc-tier: cold | canonical-for: legendary-paper-survey-46-evidence | budget: 1200tok -->
# Survey 46 — PDS wave 44 / public structure

Verdict: `found`, with source-quality debt. The deployed public article preserves every block ID, order, substantive text, table/list shape, and cached fragment; only empty paragraph scaffolds suppress visible content as designed.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; full document SHA-256 `2c0b65b64ad255a7645a94dd9ad2fed3b38d54bb93709b28efc52011fdfb6d6b`; canonical block SHA-256 `a89dd730f1697b0ce25b86ace3f88d790ef6b13e24e5519d58b3ded2c09445cd`.
- All 99 IDs are present and unique: 32 headings, 48 paragraphs, five tables, ten lists, and four callouts. Stored `body.blocks` equals canonical top-level blocks.
- The public article contains 99 direct keyed wrappers in exact source order and all 99 normalized authored block texts match. Headings render H1 ×1, H2 ×24, H3 ×7.
- Thirty-three substantive paragraphs render as `<p>`. Fifteen exact-empty paragraphs emit no text/paragraph but retain empty keyed stream wrappers.
- Tables preserve 12 explicit header cells, 54 body rows, and 203 body cells. Two source-headerless tables intentionally remain headerless; no ragged rows were found.
- All ten lists are unordered and render as semantic `<ul>` with the exact 85 item bodies. All four absent-tone callouts normalize to info.
- No marks, unknown block types, malformed headings/content, ragged tables, or malformed list items were found.
- Stored `body_html` is 75,443 bytes at SHA-256 `0cb6a0b7239ba072cea93bd9145de336034e56cf9c2c8692331f5fe2867ae816`. Its 84 nonempty fragments match the 84 nonempty public block DOMs; the 15 empty source paragraphs are absent from cache output but retain public anchors.
- Three live fetches returned HTTP 200 with identical article SHA-256 `605244c5727f19a779455aa7aff82f99f0e3bc087976994b00b26b72695d6d5d`, 99 children, exact source revision/count/hash. Missing and draft-prefixed public routes correctly return 404.

Elixir tests could not run because the pinned worktree lacks Mix dependencies. Verify should retain the exact cache/live/block parity, decide whether to repair the 15 empty source paragraphs, and add regression fixtures for the two intentionally headerless tables. No state mutation occurred.
