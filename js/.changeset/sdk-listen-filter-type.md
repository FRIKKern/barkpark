---
'@barkpark/core': minor
---

`client.listen()`'s filter type now pins the operator to `'eq'` (new exported `ListenFilter` type). Real-time matching is eq-only in Phase 1A — `filtersToRecord` already rejected non-eq ops at runtime, but the type was `QueryOptions['filters']` (any op), so `listen('post', [{ op: 'gt', … }])` compiled then threw. It's now a compile error, surfacing the constraint where you write it.
