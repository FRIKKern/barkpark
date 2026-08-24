---
'@barkpark/core': major
'@barkpark/nextjs': major
---

**Fix: patch mutations never reached the server (gh-8100).** The patch op that `@barkpark/core` put on the wire omitted `type`, but `/v1/data/mutate` dispatches a patch on `{id, type}` and rejects the request as `malformed` without it — so every `client.patch(...).commit()`, every `transaction().patch(...)`, and every `defineActions().patchDoc(...)` failed against a real server, on every document.

`type` is now part of the signature, matching `publish`/`unpublish`/`discardDraft`/`delete`, which have always taken `(id, type)`:

```diff
-await bp.patch('p1').set({ title: 'Updated' }).commit()
+await bp.patch('p1', 'post').set({ title: 'Updated' }).commit()

-await bp.transaction().patch('p1', (p) => p.set({ featured: true })).commit()
+await bp.transaction().patch('p1', 'post', (p) => p.set({ featured: true })).commit()

-await actions.patchDoc('p1', { set: { title: 'Updated' } })
+await actions.patchDoc('p1', 'post', { set: { title: 'Updated' } })
```

Breaking by signature only — the previous form could not succeed against a server, so no working call site changes behaviour. TypeScript flags every affected call at build time. Pass the document's `_type`.
