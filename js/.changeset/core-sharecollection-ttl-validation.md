---
'@barkpark/core': patch
---

`client.shareCollection()` now validates `ttl` client-side: a non-integer, `NaN`, or `< 1` value throws a self-explaining `BarkparkValidationError` (field `ttl`) instead of forwarding garbage to the server for an opaque 400/500. This matches the guard consistency of the other numeric SDK inputs (paging, graph depth, patch inc/dec). A caller computing `ttl: days * 86400` from a bad `days` now fails fast.
