---
'@barkpark/core': minor
---

`client.listen` takes an `ids` option, sent as `?ids=a,b`: the stream carries only those documents (each id matches its published and `drafts.` spelling on the server). The `listen.ts` comment no longer says the server ignores `?types=`; the server narrows by it, and the client-side type filter stays as a backstop.
