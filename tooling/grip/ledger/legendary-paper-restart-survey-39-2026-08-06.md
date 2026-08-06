<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-39 | budget: 1400tok -->
# Restart Survey 39 — PDS44 public negative capability

Assignment `restart-survey-39` challenged `pds-wave-44-2026-08-03::public` at exact Paper revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **partial failure, high confidence**. Exact 99-block source/connected-public parity is strong, but negative controls disprove robust content negotiation, error taxonomy, conditional caching, narrow geometry, table interaction, and intrinsic Paper-revision identity.

## Hash boundary

These hashes cover different serializations and are not interchangeable revision authorities:

- Raw machine Paper response including newline: 328,256 bytes, SHA-256 `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`.
- Canonical whole-Paper JSON without that newline: 328,255 bytes, SHA-256 `2c0b65b64ad255a7645a94dd9ad2fed3b38d54bb93709b28efc52011fdfb6d6b`.
- Raw source response: 76,255 bytes, `3/3`, SHA-256 `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`.
- Canonical source object, canonical block projections, dead-render article, immediate outerHTML, connected article, and normalized visible text each have method-specific hashes; none substitutes for `_rev`.

## Negative matrix

A 25-route matrix found stable HTML/source availability but exposed contract failures. Explicit JSON/plain-text Accept returns 406 labeled `internal_error`; missing-plus-JSON also collapses into negotiation failure; query perspective is ignored; unsupported methods return misleading 404 document-absence errors; and matching conditional requests return full 200 responses rather than 304.

Only the scoped public URL emits content ETag `sha256:12d846d529b8b5e7d3534627741b73137501d6ab79a076992bc665a8d8147676` and released revision `344fe5ee-c8a0-4bb9-8b5e-17a3562992d5`. Flat/dataset routes emit neither. No route exposes Paper `_rev`; article `data-rev="0"` is stream/content revision state and is not document identity.

Connected mobile containment passed at 390px, failed by 142px at 320px, failed by 137px at 240px, and failed by 364px under synthetic 2× CSS zoom. Five data tables are unnamed `role=presentation` focus stops. ArrowRight did not scroll the first table. Browser AX and real assistive technology remain unvisited, so neither is proxy-passed.

Facts above come from live source, public routes, connected browser geometry, keyboard controls, and response headers. Inference: content fidelity is mature enough to preserve authored order, while the public-reader contract is still not portable, self-identifying, cache-correct, or accessibility-safe. No claim is made about real screen readers, historical revision rendering, long-lived availability, or full automated regression coverage. Targeted tests executed zero because isolated dependencies were absent. Temporary artifacts were trashed; no repository, Paper, Task, Cycle, or production mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-39","unit":"pds-wave-44-2026-08-03::public","verdict":"partial_failure","confidence":"high","paper":{"revision":"8bbd5d874a1b697f1e4e437c473f8e52","raw_machine_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","canonical_document_sha256":"2c0b65b64ad255a7645a94dd9ad2fed3b38d54bb93709b28efc52011fdfb6d6b","raw_source_sha256":"9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7","blocks":99},"negative_matrix":{"routes":25,"accept_taxonomy":false,"perspective_honored":false,"method_taxonomy":false,"conditional_304":false},"identity":{"scoped_etag":true,"scoped_release_revision":true,"flat_dataset_headers":false,"paper_rev_visible":false,"data_rev":"0"},"geometry":{"390":"pass","320_overflow_px":142,"240_overflow_px":137,"zoom2_overflow_px":364},"tables":{"count":5,"role":"presentation","named":"0/5","arrow_scroll":false},"real_at":"unvisited","tests":{"executed":0},"mutations":0}
```
