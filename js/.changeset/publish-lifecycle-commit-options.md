---
'@barkpark/core': patch
---

`client.publish` / `unpublish` / `discardDraft` (and the standalone `publishDoc` / `unpublishDoc` / `discardDraftDoc`) now accept an optional trailing `CommitOptions` argument, matching `create` / `delete`. This lets callers opt into write retry, supply an `idempotencyKey`, or override `timeoutMs` on the publish-lifecycle mutations — a publish is exactly the write a caller wants to make idempotent on retry.
