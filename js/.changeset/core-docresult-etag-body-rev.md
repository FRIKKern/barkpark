---
'@barkpark/core': patch
---

`getDoc` now sources `DocResult.etag` from the response BODY — the `etag` field in the filtered (default) envelope, the document's own `_rev` in the flat shape — instead of the HTTP `ETag` response header. The two were the same string by coincidence; PR #15786 makes the header a CACHE VALIDATOR that additionally folds the dataset schema hash (it has to: `Envelope.render/3` picks the visible field set out of the schema and a schema edit moves no `_rev`, which is how an anonymous 304 kept serving a newly-private field). After that lands, the documented read-then-write round-trip — `const { etag } = await client.doc(t, id)` then `ifMatch: etag` — would send the folded validator and get `rev_mismatch` (412). The returned value is unchanged against a server that still emits the identity. `ResponseContext.etag` (the `onResponse` hook) keeps carrying the header and is now documented as a cache validator that must never be fed to `ifMatch`.
