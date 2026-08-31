---
'@barkpark/nextjs': patch
---

Fix the preloader's dedup key. `createPreloader` built it with `JSON.stringify([id, opts])`, which is key-order sensitive — so the same options bag written `{ type, perspective }` vs `{ perspective, type }` produced two keys and an identical preload was not deduped — and which renders every non-serializable value as `{}`, so two **different** `AbortSignal`s produced the **same** key and were wrongly collapsed onto one in-flight request. A cyclic options bag also threw inside the key builder. The key is now built by a structural encoder that sorts object keys recursively, keeps array order, treats a bare string as a scalar (so `expand: 'author'` and `expand: ['author']` stay distinct), and gives non-serializable values such as an `AbortSignal` a stable per-instance identity instead of `{}`. No change to what any request returns.
