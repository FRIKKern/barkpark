---
'@barkpark/core': minor
---

Add the `nin` (not-in-list) filter operator: `.nin(field, values)` sugar and `'nin'` in `FilterOp` / `.where()`. Matches the server's new `nin` (#340) — strict `NOT IN`, so NULL/absent rows are excluded. The array-value validation now covers both `in` and `nin`.
