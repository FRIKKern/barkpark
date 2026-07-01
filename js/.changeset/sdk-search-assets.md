---
'@barkpark/core': minor
---

**Added:** `client.searchAssets(q, opts?)` — search the media library (`GET /v1/media/:dataset/search`): full-text over asset metadata plus filters (`mimeType`/`kind`/`status`/`collection`/`tags`), facets, and keyset pagination (`cursor`/`nextCursor`/`hasMore`). `q` may be empty for a filter-only browse. The API had a full media-search subsystem, but the SDK could only paginate the whole library (`listAssets`) — not search it, a core media-library operation. Returns a `MediaSearchResult` (`hits`, `total`, `facets`, `highlights`, `parsedQuery`, …); new `SearchAssetsOptions` + `MediaSearchResult` types.
