---
'@barkpark/core': minor
---

`search()` now accepts `offset` (paginate results — the result's `count` is the total) and `type` (restrict the search to one document type). The server already supported both; `SearchOptions` just didn't expose them.
