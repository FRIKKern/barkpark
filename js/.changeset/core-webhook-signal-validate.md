---
'@barkpark/core': patch
---

Webhook CRUD parity: `listWebhooks`/`getWebhook`/`createWebhook`/`updateWebhook`/`deleteWebhook` now accept an optional `{ signal }` last arg so they're cancellable like every other core read/write. `createWebhook` also validates locally — it throws a field-tagged `BarkparkValidationError` (`field: 'name'` / `field: 'url'`) before the round-trip when either required field is empty, turning an opaque server 422 into a local error.
