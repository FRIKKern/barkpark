---
'@barkpark/core': minor
---

`client.getDocuments(type, ids, opts)` now accepts `{ signal }` (an `AbortSignal`) to cancel the batch fetch — completing cancellation support across every read method (`doc`, `docs`, `getDocuments`, `search`). The signal threads to each chunk's request.
