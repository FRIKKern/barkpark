---
'@barkpark/core': minor
---

`SearchResult` now exposes `facets`. The server computes facet buckets (`type` / `status` / `author`, each `{ label, count }` ordered by count desc) on every search and returns them as `facets`, but the SDK dropped the field — so faceted-search UIs ("N results across these facets") were impossible from `client.search()`. `search()` now parses `facets` into the result (optional, like `highlights`); the type is `Record<string, Array<{ label: string; count: number }>>`.
