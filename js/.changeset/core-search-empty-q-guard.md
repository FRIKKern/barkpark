---
'@barkpark/core': patch
---

`client.search()` now throws a `BarkparkValidationError` on an empty or whitespace-only query string instead of sending an opaque `?q=` request (fail-closed parity with other required-arg reads).
