---
'@barkpark/nextjs': patch
---

`revalidateBarkpark` now enforces the path-gate before any side effects. Previously a payload carrying both `sync_tags` and a `path`/`paths` (with `BARKPARK_ALLOW_ALL_REVALIDATE` unset) invalidated all tag caches via `revalidateTag` and only THEN threw — leaving a partial invalidation behind on the failed call. The `BARKPARK_ALLOW_ALL_REVALIDATE=1` precondition is now checked at the top of the function, so the error path is atomic: nothing is invalidated when the call throws. Happy paths are unchanged.
