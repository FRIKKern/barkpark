---
'@barkpark/nextjs': patch
---

Export `OptimisticDocumentConflict` and `UseOptimisticDocumentResult` from the `@barkpark/nextjs/actions` entry. The `useOptimisticDocument` hook was exported but its return type (`UseOptimisticDocumentResult<T>`) and the `conflict` field type (`OptimisticDocumentConflict`) weren't re-exported from the entry, so a consumer couldn't annotate the hook's result. Export-completeness sweep (cf. the core ListenOptions/doc-types fixes).
