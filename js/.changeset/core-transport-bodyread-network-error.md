---
'@barkpark/core': patch
---

Transport: a mid-body reset while reading the response now surfaces as a retryable `BarkparkNetworkError` instead of a raw `TypeError`. Both `response.text()` sites (the error-decode path and the ok/JSON path) sit outside the fetch try/catch and after the per-attempt timeout timer is cleared, so a TCP reset mid-stream rejected with a `TypeError` that escaped the error taxonomy — `defaultShouldRetry` returns false for a non-Barkpark error, so even an idempotent GET was never retried. Each `text()` is now wrapped in a catch that mirrors the fetch-level catch: a caller-initiated abort (`opts.signal.aborted`) re-throws its `AbortError` untouched so cancellation still fails fast, and any other body-read failure becomes a `BarkparkNetworkError` the read policy re-attempts. The 204 short-circuit, empty-body → `undefined`, and `JSON.parse` try/catch are unchanged.
