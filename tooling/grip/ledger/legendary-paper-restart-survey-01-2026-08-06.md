<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-01 | budget: 1400tok -->
# Restart Survey 01 — CLI/API provenance and current pin

Assignment `restart-survey-01` re-attested `cloud-console-hardening-wave-28-2026-08-03::cli_api` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **partial: content provenance passes decisively; live availability does not**.

## Direct answer

Every successful current CLI/API read resolves frozen revision `49c1534d9fb76d0d9adc7b97f25ec471` and preserves the exact 237-block source, IDs, and order across document, query, source, history, and revision-detail routes. Fresh canonical document/query requests nevertheless returned intermittent HTTP 500 responses, contradicting the earlier 120/120 availability sample.

## Equality and hashes

Fresh comparisons all passed: CLI get equals flat document, scoped document, scoped query, and CLI query; source blocks equal document blocks; flat and scoped sources equal; CLI and API revision details equal; revision blocks equal current document blocks.

- block-array SHA-256: `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`
- ordered-ID SHA-256: `af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff`
- whole-document SHA-256: `72e246bea0648c256b0667436f38a680cd4454743c6b259a99d0678712e8f92a`
- source-envelope SHA-256: `cc56593d374dc237cfcc1e4b24e9a948e8b2858fe98615a8dbdf0f326c2162cf`

All 237 block IDs are present, nonblank, and unique. Type counts: 156 paragraph, 43 heading, 18 table, 13 callout, and 7 list. First block is `w28b001` heading; last is `w28r0049` callout. No revision, block, ID, or order drift was found on a successful response.

## Fresh availability sample

- CLI get: 2/2 success.
- authenticated flat/scoped document: 5/7 success, 2/7 HTTP 500.
- CLI query by `_id`: 1/3 success, 2/3 HTTP 500.
- scoped API query by `_id`: 4/7 success, 3/7 HTTP 500.
- flat/scoped source: 2/2 success.
- history: 1/1 success.
- CLI/API latest revision: 2/2 success.

Failure request IDs: `GMkXuwgg2n55dTcAHMqS`, `GMkXu2zGYZf8804AHNDi`, `GMkXx-hyYvnplgMAHi3B`, `GMkXzLayVMRjDQkAHOvS`, `GMkXzjgErAZLxdIAHmVR`, `GMkXzmL65slu-SwAHmgh`, and `GMkX0Jdk4mJ75o8AHm9R`. Each failure used `internal_error`; identical retries often succeeded at the frozen revision. That proves intermittent availability failure, not content corruption, but does not establish root cause.

The stored document has no `slug` field, so a `slug` filter correctly returns zero; `_id` is the document identity and resolves when the request does not fail.

## Facts, inference, and residual scope

Facts are the route statuses, request IDs, exact equality results, revision, counts, and hashes above. Transience is an inference from identical retry success. Server logs, concurrency/load correlation, draft/raw, conditional reads, pagination, and other Papers/readers were not inspected.

The decisive risk is false certification from one successful retry. Content correctness and availability must remain separate gates.

## Cycle payload

```json
{"assignment_id":"restart-survey-01","unit":"cloud-console-hardening-wave-28-2026-08-03::cli_api","verdict":"partial","revision":"49c1534d9fb76d0d9adc7b97f25ec471","blocks":237,"hashes":{"blocks":"a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09","ordered_ids":"af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff","document":"72e246bea0648c256b0667436f38a680cd4454743c6b259a99d0678712e8f92a"},"samples":{"document_success":5,"document_total":7,"cli_query_success":1,"cli_query_total":3,"api_query_success":4,"api_query_total":7,"source_success":2,"source_total":2},"found":["exact successful-route provenance","intermittent HTTP 500"],"not_found":["revision drift","block or order loss","reliable current availability"]}
```
