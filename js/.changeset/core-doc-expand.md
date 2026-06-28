---
'@barkpark/core': minor
---

`client.doc(type, id)` now accepts `{ expand }` to inline reference fields on a single-document fetch (depth 1) — completing the `.expand()` support added to the list builder. E.g. `bp.doc('post', 'p1', { expand: ['author', 'tags'] })`.
