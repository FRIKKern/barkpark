---
'@barkpark/core': minor
---

Add the `hasStrong` filter operator for weighted-tag reads: `.hasStrong(field, value)` sugar and `'hasStrong'` in `FilterOp` / `.where()`. Matches the server-side op shipped in #2790 (query.ex `apply_field_op` + `parse_has_strong`) — it finds documents whose `field` array carries a tag at or above a minimum strength. Pass the scalar wire value `'<tag>:<min_strength>'` (e.g. `bp.docs('post').hasStrong('tags', 'search:40')`); the server splits on the LAST colon, so colon-bearing tag names stay safe. Being a scalar op it inherits the existing value guards (an array value is rejected like `has`).
