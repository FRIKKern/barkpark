---
'@barkpark/core': minor
---

`client.doc(type, id, { fields })` now projects single-document fetches too — pass `fields` to return only the named content fields (system fields always included), symmetric with the query builder's `.select()`. Composes with `expand`.
