---
'@barkpark/core': patch
---

`createClient` now validates `timeoutMs`: a negative, `NaN`, or non-number value throws `BarkparkValidationError` instead of being accepted. Previously such a value passed construction but left the transport's `timeoutMs > 0` guard false, silently disabling the request timeout so every request could hang forever — the exact failure the timeout exists to prevent. `0` remains valid and documented as disabling the timeout.
