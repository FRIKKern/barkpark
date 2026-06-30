---
'@barkpark/core': minor
---

`client.docs(type, opts)` now accepts `{ perspective }` (per-query perspective override) and `{ signal }` (an `AbortSignal` to cancel `.find()`/`.findOne()`/`.count()`/`.findPage()`). The underlying query operation already supported both — they were just unreachable through the client method. Cancellation is the common React-unmount / debounced-search need.
