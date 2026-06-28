---
'@barkpark/react': minor
---

`BarkparkImage` now accepts a bare URL string for `asset` — the shape Barkpark stores for image fields (e.g. `"/media/files/…"`) — prepending `baseUrl` for relative paths. Additive; the `_ref`/expanded-asset forms are unchanged.
