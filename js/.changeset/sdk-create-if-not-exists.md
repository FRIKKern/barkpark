---
'@barkpark/core': minor
---

Add `createIfNotExists` — `tx.createIfNotExists(doc)` and the top-level `bp.createIfNotExists(doc)`. The server already supports this mutation (idempotent create — no-op if `_id` is taken); the SDK now exposes it, completing the create-family for seeding/bootstrapping. Matches Sanity's `createIfNotExists`.
