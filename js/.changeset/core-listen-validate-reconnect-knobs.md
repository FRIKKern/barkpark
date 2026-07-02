---
'@barkpark/core': patch
---

`listen()` now validates its reconnect knobs: `maxReconnects` must be a non-negative integer and `reconnectBaseMs` a positive integer, otherwise it throws `BarkparkValidationError` synchronously before any connection is opened. Previously a `NaN`, negative, or fractional value passed unchecked — e.g. `reconnectBaseMs: NaN` flowed to `Math.min(NaN * 2**n, 8000) = NaN`, which `setTimeout` coerces to `0`, silently degrading exponential backoff into a zero-delay reconnect loop that hammers the server on every drop.
