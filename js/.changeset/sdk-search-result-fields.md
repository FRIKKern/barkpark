---
'@barkpark/core': minor
---

`SearchResult` now surfaces the remaining server response fields: `parsedQuery` (how the analyzer read the query), `recovery` (spelling/synonym detail beyond `correctedTo`), `truncation` (whether the engine capped the scan, so `count` is a lower bound — indx surfaces it, postgres omits), and `ms` (server-side query latency). All were on the wire but dropped by `search()`. Completes the search-result exposure begun with facets — no field the server sends is silently discarded now.
