---
'@barkpark/core': patch
---

**Docs:** the `FilterOp` type and `.where()` builder now document the null/absence-check idiom — `where(field, 'eq', null)` maps to the server's `IS NULL` and `where(field, 'neq', null)` to `IS NOT NULL` (there is no separate `is` op). This behavior existed and was tested, but was only explained in an internal encoder comment, so a consumer reading the public JSDoc had no way to discover how to query for missing/present fields. Docs only — no code change.
