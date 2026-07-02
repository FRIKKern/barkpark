---
'@barkpark/core': patch
---

`getRevision()` / `client.getRevision()` now throw `BarkparkValidationError` on an empty or non-string `revId` (parity with `getHistory` and `restoreRevision`), instead of building a collapsed `/v1/data/revision/:dataset/` request path that returned an opaque server error.
