---
'@barkpark/core': minor
---

`client.getDocuments(type, ids, opts)` now accepts `{ expand }` (inline reference fields) and `{ fields }` (projection) — the same read options as `doc()` and the query builder. Batch-fetch a list of ids and resolve their references or trim to a summary in one call.
