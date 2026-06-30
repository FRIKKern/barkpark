---
'@barkpark/core': minor
---

New `discardDraft` mutation — `client.discardDraft(id, type)` and `transaction().discardDraft(id, type)`, plus the `discardDraftDoc` helper. Drops a document's draft edits (`drafts.{id}`), leaving the published `{id}` unchanged — Sanity's "discard changes". The server already supported the `discardDraft` op (and `MutateResult.operation` already listed it); only the client method was missing.
