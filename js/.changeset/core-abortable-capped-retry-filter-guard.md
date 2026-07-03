---
'@barkpark/core': patch
---

Harden the runtime client's retry resilience and fix two overstated doc comments.

- **Abortable + capped retry backoff.** The between-attempt backoff sleep now honors the caller's `AbortSignal`: aborting during a 429/5xx wait cancels immediately (rejecting with the transport's standard `AbortError` shape) instead of blocking until the delay elapses. A server-supplied `Retry-After` is clamped to a named ceiling (`MAX_RATE_LIMIT_BACKOFF_MS`, 60s), so a hostile or misconfigured `Retry-After: 3600` can no longer pin a single request for ~1h.
- **Fail-closed filter object guard.** `makeFilterExpression` now rejects a non-Date object value on a scalar op (e.g. `eq('author', {_ref:'x'})`) with a self-explaining `BarkparkValidationError`, rather than letting it serialize to the opaque `filter[author][eq]=[object Object]` and drawing a bewildering server 400. Dates, `null`, and primitives are still accepted.
- **Doc corrections.** `retry.ts` no longer claims the Idempotency-Key is "rotated between attempts" — transport sets one stable key shared across all attempts. `image-url.ts` no longer claims `srcSet` support — renditions are fixed-size named presets, not width-parametric transforms.
