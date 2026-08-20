---
'@barkpark/core': minor
---

`searchDocuments`/`client.search()` and `searchAssets`/`client.searchAssets()` now surface the server's top-level `searchEventId` on `SearchResult`/`MediaSearchResult` (`null` when the server omits it). The API already required this id on the paired `/search/interaction` routes to report click/quality signals, but the SDK dropped it — callers had no way to obtain it at all.
