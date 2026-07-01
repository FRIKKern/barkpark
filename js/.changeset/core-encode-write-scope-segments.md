---
'@barkpark/core': patch
---

The write and listen path builders (`publish`/`unpublish`/`discardDraft`, `patch.commit`, `createTransaction().commit`, `listen`) plus the shared `scopePrefix` now wrap the `dataset`, `workspace`, and `project` path segments in `encodeURIComponent`, matching every read builder (`doc`/`docs`/`search`/`backlinks`/`history`/`media`) and the Go SDK's `url.PathEscape`. No-op for slug-valid inputs; only hardens URL construction for pathological names.
