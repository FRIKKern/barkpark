---
'@barkpark/core': minor
---

`typedClient<TMap>` now narrows `getDocuments` too, not just `doc`/`docs`. It's a type-keyed batch read (`getDocuments('post', ids)`), so with a typed client it now returns `Array<Post | null>` and rejects an unknown type key at compile time — consistent with `doc`/`docs`. (`getBacklinks`/`getGraph`/mutate/listen aren't single-type-keyed, so they stay unnarrowed by design.)
