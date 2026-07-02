---
'@barkpark/core': patch
---

CSV query-param builders now fail closed on an embedded comma in an array entry, matching the existing filter-builder guards. `search({ types })`, `getGraph({ kinds, sources })`, and `searchAssets({ tags, facets })` join array entries with `,` (the wire format the server splits on), so a comma inside an entry would silently split into extra values — an over-broad query. Each now throws `BarkparkValidationError` with the field name. Single pre-joined strings (e.g. `searchAssets({ tags: 'a,b' })`) are unchanged: the caller may intend that CSV.
