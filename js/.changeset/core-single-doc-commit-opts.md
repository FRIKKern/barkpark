---
'@barkpark/core': minor
---

The single-doc mutation shortcuts now accept `CommitOptions`: `bp.create(doc, opts)`, `createOrReplace`, `createIfNotExists`, and `delete(id, type, opts)` forward `retry` / `idempotencyKey` / `timeoutMs` to the commit (and `delete` keeps `ifMatch`). Resilient single-doc writes without dropping to an explicit transaction. Backward-compatible — `opts` is optional.
