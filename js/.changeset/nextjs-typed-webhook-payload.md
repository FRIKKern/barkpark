---
'@barkpark/nextjs': minor
---

`createWebhookHandler`'s `onMutation(payload)` callback now receives a **typed** payload — `@barkpark/core`'s `WebhookEvent` (`event`/`type`/`doc_id`/`sync_tags`/`dataset`/… all typed) instead of `Record<string, unknown>`. The wire shape now has a single source of truth shared with the core SDK (plus the handler's optional `deliveryId` dedup-fallback field). Existing handlers keep working — the payload type just got richer.
