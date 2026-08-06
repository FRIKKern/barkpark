<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-22 | budget: 2100tok -->
# Restart Verify 22 — Paper identity graph and conditional validators

Assignment `restart-verify-22` tested four frozen Papers across document revision, newest-history release, public page, source, query, and Cycle identity domains. Verdict: **refuted**. The identities that exist join reproducibly, but the source exposes no ETag and an exact public-page ETag does not produce a conditional response.

| Measure | Observed |
|---|---:|
| Frozen document `_rev` joins | 4/4 |
| Newest-history UUID/detail joins | 4/4 |
| Newest-history blocks equal current | 4/4 |
| Query blocks equal current | 4/4 |
| Query ETag formula exact | 4/4 |
| Source ETag present | 0/4 |
| Exact page ETag returns 304/empty | 0/4 |
| Exact query ETag returns 304/empty | 4/4 |
| Stale validators return 200/nonempty | 12/12 |
| Request IDs | 24/24 |
| 5xx | 0/24 |

The document ID joins source, query, and history detail for all four Papers. The page `x-barkpark-paper-revision` equals the newest history UUID 4/4. The query ETag equals the first 32 hexadecimal characters of `sha256("production|paper|<id>:<document_rev>")` 4/4. Present document, history-release, page, query, and Cycle identities remain pairwise distinct 4/4; no equivalence was inferred from equal content.

For exact conditional requests, source returned 200 with full content and no ETag 4/4, page returned 200 with full content and its unchanged ETag 4/4, and query alone returned 304 with an empty body 4/4. All twelve deliberately stale controls returned 200 with nonempty current content. Therefore the requested complete validator-domain equivalence passes 0/4.

The sole denominator is the corrected 24-cell HTTP/1.1 run. A preliminary harness run was discarded because curl did not create files for empty 304 bodies. Scope excludes drafts, older history entries, post-mutation validator changes, and weaker actors. Mutations were zero, saved-token-file hits were zero, and the repository remained clean at `f34d6d9e0f3a3ba16f2e0338da1520a84c02b29c`.

Evidence root is `/private/tmp/bp-restart-verify22-606dc2c9-r2`. Evidence SHA-256 is `23885a5c40edc29fa600cac9b30d8cd0d78de70187188bf44c5e5852692093ac`; conditional matrix SHA-256 is `8bb4770d1097df8417ec6ddafe70384120d49e82e2c755fe7b3c1a17ffdd5cee`; authoritative identity graph SHA-256 is `ef6194fbe221b649b9a66f75627a90e5b14f14c301a347c2a8ab4b7034cf8acf`; page-release-header SHA-256 is `1747f8434f39a7f228b3bcb346324cf151df1b2cdd11a3fee50ec66077f87ea3`.

## Cycle payload

```json
{"assignment_id":"restart-verify-22","assignment_uuid":"606dc2c9-1294-42fb-b2c0-a9186b9d6a09","verdict":"refuted","joins":{"document_revision":"4/4","document_id":"4/4","history_uuid_detail":"4/4","history_release_uuid":"4/4","newest_history_blocks_current":"4/4","query_blocks_current":"4/4","query_etag_formula":"4/4"},"identity":{"source_etag_present":"0/4","page_etag_present":"4/4","query_etag_present":"4/4","present_domains_pairwise_distinct":"4/4","cycle_revision":"8a94f6db-1be6-4bbf-ba49-7f3aeed0e737"},"conditional":{"planned":24,"curl_zero":24,"request_ids":24,"source_exact_304_empty":0,"page_exact_304_empty":0,"query_exact_304_empty":4,"stale_200_nonempty":12,"five_xx":0},"mutations":0,"saved_token_file_hits":0,"evidence_sha256":"23885a5c40edc29fa600cac9b30d8cd0d78de70187188bf44c5e5852692093ac"}
```
