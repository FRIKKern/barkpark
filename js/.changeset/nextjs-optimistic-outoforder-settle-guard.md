---
'@barkpark/nextjs': patch
---

Fix `useOptimisticDocument.mutate` committing every server response unconditionally, so an older mutation whose round-trip settled after a newer one clobbered the newer committed document and silently dropped a persisted patch. Each `mutate` call now takes a monotonic sequence at entry and commits `setCommitted`/`committedRef`/the `latestRef` re-sync only when its sequence is the newest seen, making a late-arriving older response a no-op.
