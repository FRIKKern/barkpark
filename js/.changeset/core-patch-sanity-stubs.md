---
'@barkpark/core': minor
---

The patch builder now declares the common Sanity patch ops `dec` / `setIfMissing` / `unset` (joining `inc`) as Phase-1A stubs that throw a clear, actionable "not implemented; use patch.set …" error. Previously a migrant reaching for them got a cryptic "x is not a function".
