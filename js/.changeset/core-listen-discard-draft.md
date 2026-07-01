---
'@barkpark/core': patch
---

client.listen() now recognizes the `discardDraft` mutation kind. The server broadcasts it, but the SSE parser previously whitelisted only five actions, so a discard-draft event arrived with `mutation === undefined`. The `ListenEvent.mutation` union is widened to include `'discardDraft'`.
</content>
