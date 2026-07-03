---
'@barkpark/core': patch
---

Don't retry (or mislabel) a caller-aborted request. When a read was cancelled
via its `AbortSignal` (a React unmount, a Next.js navigation), transport wrapped
the resulting `AbortError` as a retryable `BarkparkNetworkError` and re-tried it
up to 3× with backoff (~900ms wasted) before finally rejecting — and callers
couldn't tell an intentional cancel from a real network failure. A user-signal
abort now re-throws the standard `AbortError` (detectable via
`err.name === 'AbortError'`, as with a bare `fetch`) and fails fast; genuine
fetch-level failures (DNS/offline/TLS) stay a retryable `BarkparkNetworkError`.
Timeouts are unchanged (`BarkparkTimeoutError`).
