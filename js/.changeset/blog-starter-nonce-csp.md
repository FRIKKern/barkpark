---
'create-barkpark-app': patch
---

blog-starter: ship a per-request-nonce Content-Security-Policy as defense-in-depth. A new `middleware.ts` mints a fresh nonce per request and sets a strict CSP (`default-src 'self'`; `script-src 'self' 'nonce-…' 'strict-dynamic'` with NO `'unsafe-inline'`; `object-src 'none'`; `base-uri 'self'`; `frame-ancestors 'none'`) on both the forwarded request headers and the response, so Next tags its own inline hydration scripts with the nonce and static routes keep their posture. A new `lib/csp.ts` holds the pure `buildCspPolicy(nonce)` builder and a Web-Crypto `generateNonce()`. This means even if the trusted `renderPortableDocument` emitter ever regressed, an injected `<script>` still could not execute — it would lack the nonce. `layout.tsx` and `next.config.mjs` are unchanged.
