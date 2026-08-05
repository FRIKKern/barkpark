<!-- doc-tier: cold | canonical-for: legendary-paper-survey-25-evidence | budget: 1200tok -->
# Survey 25 — PDS wave 45 / Email structure

Verdict: `found`. Production email contains every nonblank block in source order; exactly 124 empty paragraph scaffolds emit zero bytes, with no malformed, nonblank-omitted, or reordered blocks.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; source 91,515 bytes / SHA-256 `e19503ef0f854680056c1857d2d9647dbfdafb2a172e7cabc75d67652f1514e8`; email 119,290 bytes / SHA-256 `3e29bd380466e0db716ec4bc67a197a38206a757ebf7f5157f98da70fd39a900`.
- Inventory: 227 blocks—166 paragraphs, 33 headings, 12 tables, nine callouts, seven lists—with present/unique IDs and valid outer shapes.
- Production email contains all 103 nonblank blocks in monotonic source order after entity decoding and tag stripping; zero nonblank omissions or reorderings were found.
- The remaining 124 blocks are exact empty paragraphs. Each emits an empty byte string under the blank-paragraph suppression contract.
- Nine tables omit `head`/`header`; this is accepted source shape, not structural malformation. Headerless data remains rendered.
- Controller selects canonical reader blocks, resolves tasks/links, avoids inserting a duplicate title because the Paper begins with H1, and renders through an order-preserving map/join.
- Flat and scoped-default source/email routes both return 200. The HTML is a standalone inline-style document; no message was sent.

Per-block deployed-render instrumentation, deployed-SHA attestation, and complete current-state reads for several named PDS tasks remain unvisited. Production hashes are point-in-time, though this Paper contains no live task blocks. No state mutation occurred.
