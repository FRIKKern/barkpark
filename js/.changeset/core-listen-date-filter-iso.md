---
"@barkpark/core": patch
---

`listen()`: Date (and Date-array) filter values now encode as ISO-8601, matching the
query builder. Previously the SSE filter loop used a bare `String(v)`, which turned a
`Date` into a locale string (`Thu Jul 02 2026 …`) the server could never match —
silently no-matching the realtime filter. Encoding now mirrors `buildQueryString`'s
`toISOString()` normalization so read-path and listen-path filters wire-encode identically.
