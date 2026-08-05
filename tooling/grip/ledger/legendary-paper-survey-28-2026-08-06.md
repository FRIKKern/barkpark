<!-- doc-tier: cold | canonical-for: legendary-paper-survey-28-evidence | budget: 1200tok -->
# Survey 28 — PDS wave 45 / CLI and API structure

Verdict: `found`. The pinned public source, raw document, filtered query, `bp doc get`, and `bp paper view -o json` preserve the same canonical 227-block array in exact order.

- Authority: `pds-wave-45-2026-08-03@b992fd8aaa028b0dab30a8da76f077fd`; canonical block-array SHA-256 `5c9e77f2af56751516862425db7abfbfadc924cb9c5e8aab770cda67e9acc673`.
- Inventory: 166 paragraphs, 33 headings, 12 tables, nine callouts, and seven lists; 227/227 blocks have unique nonblank IDs.
- The top-level `blocks` array equals `body.blocks`. Public source exposes a deliberately narrow `{_rev,id,source,title}` projection; document/query endpoints add reserved identity and envelope metadata; CLI document commands intentionally unwrap the API `result` envelope.
- All checked projections retain identical first/last IDs, array order, and canonical hash. The outline is one H1, 23 H2, nine H3, with zero level jumps.
- Exactly 124 paragraphs have literal `content:[]`; all have only `content,id,type`. There are zero empty strings, whitespace-only strings, null fields, empty objects, missing paragraph payloads, or duplicate IDs. An earlier manual count of 129 was withdrawn after a reproducible `jq` recount.
- History contains ten newest-first revisions. The newest detail was inspected; all ten content snapshots were not diffed.
- Human `bp paper view` reads canonical public source, while `-o json` intentionally returns the broader raw Paper compatibility shape.
- Projection omissions are intentional: field selection retains reserved system keys plus selected fields, while public source omits timestamps, caches, description, tags, preview, style, and draft metadata.
- The root task and immutable Legendary Cycle were read back: 20 reader units, 30 surveys started, 27 terminal when inspected, and zero failures.

Full revision-by-revision history diffs, Studio/TUI/email parity, table rectangularity, full task-corpus prior-art search, and executable test runs remain unvisited. No state mutation occurred.
