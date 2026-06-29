---
'@barkpark/core': minor
---

Add top-level single-mutation conveniences `bp.create(doc)`, `bp.createOrReplace(doc)`, and `bp.delete(id, type)` — each is one atomic transaction commit, matching Sanity's client API. Previously only `bp.patch()`/`bp.publish()` were top-level; create/delete required an explicit `transaction()`.
