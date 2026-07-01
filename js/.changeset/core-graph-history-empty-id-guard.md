---
'@barkpark/core': patch
---

core: guard the empty id in `getBacklinks`, `getGraph`, and `restoreRevision`. These three ops splice a caller-supplied id into an `encodeURIComponent` path segment but do NOT return null-on-404, so an empty id previously collapsed the request path (e.g. `/v1/data/backlinks/production/`) and surfaced as an opaque server 404 instead of a self-explaining client error. They now throw a `BarkparkValidationError` up front — `getBacklinks`/`getGraph` on an empty `id`, `restoreRevision` on an empty `revId` or `type` — matching the guard every sibling write/non-nullable path already enforces. Null-returning reads (`getDoc`/`getAsset`/`getSchema`/`getRevision`) are deliberately left alone: empty-id-as-not-found is defensible there. No network request is made when the guard fires.
