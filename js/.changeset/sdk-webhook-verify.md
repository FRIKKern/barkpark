---
'@barkpark/core': minor
---

Added `verifyWebhookSignature()` — a runtime-agnostic webhook signature verifier (Web Crypto, no `node:crypto`), so any consumer can authenticate Barkpark webhook deliveries: Express/Hono/Fastify, edge runtimes, workers — not just Next.js (whose `@barkpark/nextjs` handler is Node-only). It mirrors the dispatcher's `x-barkpark-signature: t=<unix>,v1=<hex>` header (HMAC-SHA256 over `"<t>.<body>"`), supports secret rotation (`previousSecret`), enforces a freshness window (`toleranceSeconds`, default ±5 min) for replay defense, uses a constant-time compare, and returns `false` (never throws) on a bad/malformed signature.
