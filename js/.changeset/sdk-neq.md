---
'@barkpark/core': minor
---

Add the `neq` filter operator: `.neq(field, value)` sugar and `'neq'` in `FilterOp` / `.where()`. Matches the server's new `neq` (#338) — strict `!=`, so NULL/absent rows are excluded.
