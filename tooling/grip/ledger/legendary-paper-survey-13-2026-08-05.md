<!-- doc-tier: cold | canonical-for: legendary-paper-survey-13-evidence | budget: 1200tok -->
# Survey 13 — wave 29 / CLI and API structure

Verdict: `found`. Every canonical machine reader preserves the pinned document fields, 252 blocks, IDs, and order exactly; remaining defects are source quality or audit vocabulary, not transport loss.

- Authority: revision `18768b0a14c2eead927181c4a0e37c18`; document SHA-256 `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15`; block-array SHA-256 `e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21`.
- `bp doc get`, `bp paper view -o json`, scoped/flat document APIs, queries, and scoped/flat source APIs agree canonically. Latest published history content also agrees.
- All 252 block IDs are present and unique; no block is missing, reordered, or transport-normalized.
- The corpus contains 187 paragraphs, 37 headings, 13 lists, 11 tables, and four callouts. Of the paragraphs, 139 are empty spacer scaffolds.
- All 11 tables use legacy `header`; the server accepts `head || header`, while `scripts/paper_quality.py` checks only `head`. Its 11 missing-header findings are false positives.
- Two stored HTML projections differ: `body_html` is 87,106 bytes; `body.html` is 120,746 bytes. Both survive transport, but their intended lifecycle remains unproven.
- The source endpoint intentionally projects only id, title, revision, kind, and blocks; omission of metadata and derived HTML is contractual, not data loss.

Draft/raw, older history revisions, conditional ETag reads, Studio, public, TUI, email, and source-ingest provenance remain unvisited by this assignment. No state mutation occurred.
