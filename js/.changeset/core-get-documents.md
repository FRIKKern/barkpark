---
'@barkpark/core': minor
---

New `client.getDocuments(type, ids)` — batch-fetch documents by id, returned in the SAME order as `ids` with `null` for any missing one (Sanity's `getDocuments` contract). One request per 1000 ids; `[]` for an empty list. Built over the `.in('_id', …)` filter, so it goes through the standard scoped query path.
