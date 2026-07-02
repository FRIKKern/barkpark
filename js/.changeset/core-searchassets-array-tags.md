---
'@barkpark/core': minor
---

`searchAssets()` `tags` and `facets` options now accept a `string[]` (joined to the comma-separated param the server expects) in addition to a comma-separated string — so `{ tags: ['animal', 'cat'] }` works without manual `.join(',')`.
