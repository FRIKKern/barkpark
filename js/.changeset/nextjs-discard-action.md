---
'@barkpark/nextjs': minor
---

`defineActions` now includes `discardDraft(id, type)` — the Server Action for discarding a document's draft edits (Sanity's "discard changes"), built on core's new `client.discardDraft` (#440). Fans out `doc:<id>` + `type:<type>` revalidate tags like the other actions. The mutation set is now complete: `createDoc` / `patchDoc` / `publish` / `unpublish` / `discardDraft` / `deleteDoc`.
