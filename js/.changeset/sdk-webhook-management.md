---
'@barkpark/core': minor
---

**Added:** webhook management — `client.listWebhooks()` / `getWebhook(id)` / `createWebhook(input)` / `updateWebhook(id, input)` / `deleteWebhook(id)` over `/v1/webhooks/:dataset`. The SDK had receive-side webhook *verification* (`verifyWebhookSignature`) but no way to *register/manage* webhooks, though the API + CLI both did — so programmatic webhook setup (provisioning, migrations, CI) needed a raw fetch. Managing webhooks is a Sanity/Strapi flagship. New `Webhook`, `CreateWebhookInput`, `UpdateWebhookInput` types. Kept in a new `webhooks.ts` module so `verifyWebhookSignature` stays transport-free and tree-shakeable.
