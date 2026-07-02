---
'@barkpark/nextjs': patch
---

Fix `useOptimisticDocument.mutate` building the server payload from a stale render-closure `committed`, which silently dropped in-flight patches on rapid successive edits. Payloads now chain through a ref so back-to-back mutations accumulate instead of clobbering each other.
