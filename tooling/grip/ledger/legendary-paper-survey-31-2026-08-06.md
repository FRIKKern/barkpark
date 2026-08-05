<!-- doc-tier: cold | canonical-for: legendary-paper-survey-31-evidence | budget: 1200tok -->
# Survey 31 — Cloud Console wave 28 / Public structure

Verdict: `found`. The pinned public reader preserves all 237 source blocks in exact order; its dominant structural defect is 103 empty paragraphs retained as empty DOM wrappers.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; block-array SHA-256 `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`; ordered-ID SHA-256 `af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff`.
- Inventory: 43 headings, 156 paragraphs, 18 tables, 13 callouts, and seven lists. All 237 IDs are unique and nonblank; zero malformed or unknown top-level blocks.
- Exactly 103 paragraphs contain `content:[]`; zero are whitespace-only. The remaining 134 substantive blocks render non-empty wrappers, while the 103 spacers render exactly 103 empty wrappers.
- The deployed reader has 237 unique `data-block-id` wrappers. Its first/last IDs and full order hash exactly match source; zero substantive blocks are missing, duplicated, or reordered.
- All 18 tables use `header`: 57 nonempty header cells, 155 body rows, 466 nonempty body cells, and zero row-width mismatches.
- Inline inventory is 750 valid text nodes, including 26 strong-marked and 41 code-marked nodes. Seven lists contain 35 nonempty items.
- Four source callouts use noncanonical `tone:"warn"` and normalize silently to `info`; one missing tone also defaults to `info`. Deployed classes total ten info and three warning.
- The public article exposes `data-rev="0"`, a LiveView streaming revision rather than the pinned document revision; gap-recovery safety is not proven here.

Full text-byte equivalence and browser layout/overflow were outside this structure lens. Verify should cover removal of 103 empty spacers, `warn` compatibility, and `data-rev=0` delta recovery. No state mutation occurred.
