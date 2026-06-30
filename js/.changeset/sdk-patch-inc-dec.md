---
'@barkpark/core': minor
---

`patch().inc(fields)` and `patch().dec(fields)` are now implemented (Phase-1B). Each takes a `{ field: number }` map and adjusts numeric content fields (a missing field counts as 0), composing with `set()`/`unset()` in one commit: `client.patch(id).inc({ views: 1 }).dec({ stock: 2 }).commit()`. Deltas are validated client-side (plain object, finite numbers, no system fields). Requires the server's `patch.inc`/`patch.dec` support (shipped in #481).
