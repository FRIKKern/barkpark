---
'@barkpark/nextjs': minor
---

`defineActions().patchDoc` now accepts the full Phase-1B patch surface, not just `set`: `setIfMissing`, `unset`, `inc`, `dec`, `append`, and `prepend` (keyed by field name). A Next.js Server Action can now `inc` a view counter or `append` a tag in one call — matching the core `client.patch()` builder. `set`-only callers are unaffected.
