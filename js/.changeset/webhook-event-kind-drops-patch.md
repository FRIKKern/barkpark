---
'@barkpark/core': patch
---

`WebhookEventKind` no longer lists `'patch'`. The server never dispatches a webhook with that action — a patch mutation is reported with the generic storage-shaped action it actually took ("update" for an existing draft, "create" for a fresh fork) — and now refuses to create a webhook subscribed to it (task-2195336df2daf576). Type-only change; the `(string & {})` arm already covered any value a caller had typed through.
