---
'@barkpark/nextjs': patch
---

The webhook handler (`createWebhookHandler`) no longer imports `node:crypto` — it verifies the HMAC via `@barkpark/core`'s Web Crypto `verifyWebhookSignature`, so it now runs in the **Edge runtime** too, not just Node. Behavior is unchanged: the same `bad_signature` / `stale` / `bad_request` responses, freshness window, secret rotation, and delivery dedup. The two HMAC implementations are now one (core's), so they can't drift.
