---
'@barkpark/core': patch
---

Add and export a `WebhookEventKind` union (`'create' | 'update' | 'delete' | 'publish' | 'unpublish' | 'discardDraft' | 'patch' | (string & {})`) matching the server's `@valid_events`, and type `WebhookEvent.event`, `Webhook.events`, and `CreateWebhookInput.events` with it instead of bare `string`/`string[]`. Corrects the past-tense JSDoc/README examples (`'created'`/`'updated'`/`'document.published'`) — a wire format emitted nowhere — to the real present-tense verbs, so a `event.event === '…'` branch actually fires. Types + docs only; no runtime or wire change.
