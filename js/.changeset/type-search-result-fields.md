---
"@barkpark/core": patch
---

`SearchResult.recovery`/`SearchResult.truncation` and `MediaSearchResult.parsedQuery` are now typed objects (each with an index signature for forward-compat with engine-specific keys) instead of `unknown`, so consumers can read fields like `truncation.truncated` or `recovery.correctedTo` without an `as any` cast.
