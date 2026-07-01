---
'@barkpark/core': minor
---

**Added:** `client.upsertSchema(schema)` and `client.deleteSchema(name)` — register (create/replace) and remove content-type schemas via `POST /v1/schemas/:dataset` and `DELETE /v1/schemas/:dataset/:name`. The SDK could read schemas (`schemas()`/`getSchema()`) but not manage them, so programmatic content-type setup (migrations, CI, provisioning scripts) required a raw fetch. `upsertSchema` is an idempotent upsert and throws `BarkparkValidationError` on an invalid definition; `deleteSchema` returns `{ deleted: name }`. New `UpsertSchemaInput` type.
