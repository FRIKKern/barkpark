---
"@barkpark/nextjs": patch
---

Fix `@barkpark/nextjs`'s server `barkparkFetch` error decoder (`decodeAndThrow`), which had
drifted from `@barkpark/core`'s `decodeErrorAndThrow`: it now reads the response envelope's
`error.code` / `error.message` / `error.hint` / `request_id` and sets `serverCode` + `hint` on
every thrown error (previously every throw was a bare `barkparkFetch: <status> <url>` string with
`serverCode` always undefined); 5xx responses now map to `BarkparkAPIError` instead of the
misleading `BarkparkNetworkError` (reserved for `fetch()` itself throwing — DNS/offline/TLS); 422
responses now map to `BarkparkValidationError` with `issues` populated from the envelope's
`details` field→message map (previously there was no 422 branch at all). Additive error
enrichment only — no public API or thrown-error-class signature change for already-passing call
sites.
