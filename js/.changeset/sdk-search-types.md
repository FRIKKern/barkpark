---
'@barkpark/core': patch
---

**Added:** `SearchOptions.types` — a multi-type allowlist for `client.search()`, sent as the `types` CSV param (`?types=post,author`). The search API already supported cross-type search via `parse_types`, but the SDK only exposed a single `type`, so consumers couldn't search across several document types in one call without dropping to a raw fetch. An empty array sends nothing (no restriction). `type` (single) is unchanged.
