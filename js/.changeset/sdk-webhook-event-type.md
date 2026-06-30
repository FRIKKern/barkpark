---
'@barkpark/core': minor
---

Added a typed `WebhookEvent` interface and a `parseWebhookEvent(body)` helper for handling incoming webhooks. The SDK already verified signatures (`verifyWebhookSignature`) but left the payload untyped — now `parseWebhookEvent<Post>(body)` gives you `{ event, type, doc_id, document, dataset, workspace, project, sync_tags, timestamp }` with the `document` typed via a generic. Field names mirror the dispatcher's wire shape.
