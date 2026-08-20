---
'@barkpark/core': patch
---

`SearchResult` gains `engineUsed` — the server-reported retriever that ACTUALLY served the search (the query pipeline emits it into the envelope; `"postgres"` even when another engine was requested but silently substituted via zero-hit recovery). `SearchOptions.engine` drops the retired `'indx'` union literal — the open `(string & {})` escape still accepts any registered engine name, so no caller code breaks.
