---
'@barkpark/nextjs': minor
---

New `@barkpark/nextjs/csp` subpath: `buildCspPolicy`, `generateNonce`,
`createCspMiddleware` and `cspMatcher` — the per-request-nonce
Content-Security-Policy that shipped as five hand-forked template copies, now
one Edge-safe implementation with the three measured variance points
(`img-src`, `connect-src`, extra script hosts) as typed options. The security
floor is fixed and `script-src` refuses `'unsafe-inline'`/`'unsafe-eval'`.
Additive — no existing export changes, and the new chunk is 827 B brotli.
