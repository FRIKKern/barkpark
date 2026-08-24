---
'@barkpark/core': patch
'@barkpark/nextjs': patch
---

The publish wall's advisories now reach the caller. Barkpark's mutate endpoint drains a non-blocking `warnings` list onto the 200 body of every successful write — the label-spine tag-count norm, the E4 dedup wall's "this looks like an existing document" band, the task plugin's merge-gate notice. `MutateEnvelope.warnings` had been declared in the SDK's public types since that channel shipped, and no runtime path in either package ever read it.

The batch helpers were fine: `client.create` / `createOrReplace` / `createIfNotExists` / `delete` and `transaction().commit()` return the whole envelope, warnings included. The damage was in the six calls that narrow the envelope to its single result — `client.publish`, `client.unpublish`, `client.discardDraft`, `client.patch().commit()`, and `@barkpark/nextjs`'s `createDoc` / `deleteDoc`. Each pulled `results[0]` and let `warnings` fall on the floor. Publishing is exactly what the wall advises on, so the calls the channel exists for were the only calls that could not see it: the write returned a clean receipt and the advice reached nobody.

All six now carry the advisories through as `MutateResult.warnings`. The key is OMITTED — never an empty array — when the server sent none, matching the server's own omit-when-empty shape, so `'warnings' in result` is a real test rather than one that is always true. Advisories remain non-blocking by contract: their presence never means the write failed.

Two type fixes ride along. `MutateWarning.severity` was declared as the single literal `'advisory'`, which made the `'warning'` the dedup wall actually sends unassignable and a `severity === 'warning'` comparison a compile error — the client type was narrower than the wire; it is now `'advisory' | 'warning'` with an open arm for future bands. And `MutateWarning` itself was never exported from `@barkpark/core`, so a consumer could receive the list but could not name what it held.

No bundle cost: the three publish-lifecycle helpers were byte-identical copies differing only in a mutation key and two strings, and folding them into one request builder more than pays for the carry-through (ESM 16.28 → 16.26 kB, CJS 16.97 → 16.95 kB gzipped).
