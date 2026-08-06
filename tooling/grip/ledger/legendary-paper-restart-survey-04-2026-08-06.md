<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-04 | budget: 1400tok -->
# Restart Survey 04 — email provenance and current pin

Assignment `restart-survey-04` re-attested `cloud-console-hardening-wave-28-2026-08-03::email` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **current pin reproduced and route output stable; revision provenance requires external source/document attestation**.

## Direct answer

The current published email preview is reproducibly derived from Paper revision `49c1534d9fb76d0d9adc7b97f25ec471`. Three email routes across three rounds produced the same 170,149-byte HTML in 9/9 requests. Published source and document agree exactly on revision and all 237 blocks. The HTML contains neither revision nor block IDs, so it cannot independently identify its source; the provenance bundle must include source/document evidence.

## Identity chain

- Source kind `blocks`; 237 blocks.
- Canonical compact block SHA-256: `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`.
- Ordered block-ID SHA-256: `af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff`.
- Flat and scoped source responses: byte-identical, 130,346 bytes.
- Source/document comparison: revision equal and blocks equal, both 237.
- Email SHA-256: `cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621`.
- Normalized visible-text SHA-256: `0bc0fe37d665614ca899affc10a6d5d841ce2f9e5f98b3e9442703e48ce77a2e`.

The sampled routes were flat `/papers/:id/email`, dataset `/d/production/papers/:id/email`, and scoped `/w/default/p/default/papers/:id/email`. All were HTTP 200 and byte-identical. Current structure: 94,483 visible characters, 14,483 words, 43 headings, 53 paragraphs, seven lists/35 items, 18 tables, 57 header cells, 466 data cells, 642 inline-style attributes, and zero style tags, scripts, invalid links, or unknown-block markers.

The inspected controller fetches published source, resolves task widgets, prepares email blocks, retains an authored H1, and renders with email style. This chain plus contemporaneous source/document equality strongly establishes the current pin, but it is not cryptographically self-contained in the resulting HTML.

## Ambiguity and contradiction

The HTML `<title>` uses the shorter Paper row title while the body H1 retains the longer authored heading. This is display-identity ambiguity, not source-block drift. The output contains zero `data-block-id` markers and no exact revision string. No source block drift, route-specific email drift, malformed links, scripts, style blocks, or unknown-block fallbacks were found.

Email availability itself was stable at 9/9. The supporting provenance chain was not: an initial flat-document request returned HTTP 500 (`GMkYSAss7oCe0CEAHi1y`) before three successful retries, and CLI capability discovery returned HTTP 500 (`GMkYSNUcbMsUwm8AHjQS`). Those failures contradict any broader claim that end-to-end provenance retrieval is failure-free.

## Facts, inference, and residual scope

Facts are the current hashes, equality comparisons, nine route results, structure counts, inspected transformation chain, and request IDs above. The exact originating revision is a strong inference from that combined evidence because the email lacks its own identity carrier. Real delivery, Gmail/Outlook screenshots, historical revisions, republish races, negative authorization, unpublished content, and frozen regression comparison were outside this lens.

## Cycle payload

```json
{"assignment_id":"restart-survey-04","unit":"cloud-console-hardening-wave-28-2026-08-03::email","paper_revision":"49c1534d9fb76d0d9adc7b97f25ec471","blocks":237,"blocks_sha256":"a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09","ordered_ids_sha256":"af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff","email_samples":{"routes":3,"rounds":3,"ok":9,"total":9,"bytes":170149,"sha256":"cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621","text_sha256":"0bc0fe37d665614ca899affc10a6d5d841ce2f9e5f98b3e9442703e48ce77a2e"},"source_doc_equal":true,"self_identifying_email":false,"ambiguities":["row-title/authored-h1 divergence","email omits revision and block IDs"],"contradictions":["supporting document/capabilities paths emitted transient 500s"],"verdict":"current pin reproduced; route output stable; revision provenance requires external source/doc attestation"}
```
