---
'@barkpark/core': minor
---

Add the `has` filter operator: `.has(field, value)` sugar and `'has'` in `FilterOp` / `.where()` — array membership, matching the server's new `has` (#350). `bp.docs('post').has('tags', 'tag-x')` finds posts whose `tags` array contains the value (as a `{_ref}` or scalar).
