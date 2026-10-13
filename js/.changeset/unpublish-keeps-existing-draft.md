---
'@barkpark/core': patch
---

`unpublish` keeps an existing draft. The server used to overwrite `drafts.{id}` with the published content, which silently destroyed unpublished draft edits. Now unpublish deletes the published `{id}` and leaves an existing `drafts.{id}` unchanged; only when there is no draft does it create one from the published content, as before. The SDK call is unchanged; `client.unpublish`, `unpublishDoc` and the transaction builder's `unpublish` docs now describe this.
