<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-31 | budget: 1400tok -->
# Restart Survey 31 — PDS44 CLI/API provenance and current pin

Assignment `restart-survey-31` re-attested `pds-wave-44-2026-08-03::cli_api` at exact revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **machine provenance passes; human CLI identity is external and semantic fidelity is partial**.

Erratum: commit `62d458133` and immutable result `restart-survey-31-result-v1` omitted `c3` from the full-document SHA. Fresh 3/3 capture in Survey 34 proves the corrected 64-character value used below; immutable history remains visible.

## Direct answer

Machine CLI and API surfaces consistently resolve the exact published Paper: 99 unique ordered blocks from `b1` through `dbf34`; document SHA-256 `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`; source SHA-256 `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`; canonical block SHA-256 `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce`; ordered-ID SHA-256 `1b0a3bf27f0ef9f06046c083109a724ba04595e6b8c1d8b39f542f33de604b58`.

`paper view -o json`, `doc get`, exact-ID query, flat/scoped document and source APIs, all three perspectives, and latest history-detail blocks matched after dynamic wrapper timing was removed. Direct `drafts.<slug>` lookup returned 404, so drafts perspective currently falls back to published rather than proving a draft twin.

Human CLI output is deterministic but not self-identifying. Three width-80 samples were byte-identical: 1,305 lines, 111,922 bytes, max width 80, zero overflow, SHA-256 `cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076`, with zero slug or revision occurrences. The direct body is the first 1,285 lines (110,831 bytes; SHA-256 `b89f0787a79e19b3ab5e916259e5c783d1a3ed2a1cce9d4468d8b9fbe56fe5c9`). The final 20 lines are five Related entries from an independent fail-open read outside Paper revision authority.

## Route and fidelity boundaries

- Published/drafts/raw machine CLI, `doc get`, and exact-ID queries passed `3/3` each.
- Authenticated flat/scoped source passed `6/6`; anonymous flat/scoped source passed `2/2` and matched. Source is private-revalidate JSON with no ETag or Last-Modified.
- Authenticated flat/scoped document passed `6/6`. Anonymous flat passed; anonymous scoped returned 403.
- History has 12 events. Latest revision-detail blocks equal current content, but document `_rev` appears zero times in history/list detail.
- Machine block/order fidelity passes. Human semantics do not: 15 empty paragraphs render no node, and three tables carry 12 canonical cells under `header` while the renderer reads `head`, omitting those header bands.

Identity is therefore reconstructible through source/block/output hashes, not provable from pasted terminal output. Related was stable across two reads (ten candidates, SHA-256 `af31d416b8704fd8adc58b169f90f55c7c62178abd3fbad6ce80c8744251a181`) but remains mutable and unpinned. Interactive TUI, browser, Studio, email, other widths/themes, and alternate terminals were not visited. Targeted `internal/cli` and `internal/apiclient` tests passed. Temporary captures were moved to Trash; no state mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-31","unit":"pds-wave-44-2026-08-03::cli_api","verdict":"machine provenance pass; human identity external; semantic fidelity partial","paper":{"revision":"8bbd5d874a1b697f1e4e437c473f8e52","blocks":99,"document_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","source_sha256":"9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7","blocks_sha256":"1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce","ordered_ids_sha256":"1b0a3bf27f0ef9f06046c083109a724ba04595e6b8c1d8b39f542f33de604b58"},"machine":{"perspectives":"identical","draft_twin":false,"block_order":"found"},"human":{"samples":"3/3 identical","lines":1305,"bytes":111922,"sha256":"cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076","visible_identity":false,"empty_paragraphs_dropped":15,"table_headers_omitted":12},"related":{"candidates":10,"cli_entries":5,"revision_bound":false},"history":{"events":12,"latest_blocks_equal":true,"document_rev_visible":false}}
```
