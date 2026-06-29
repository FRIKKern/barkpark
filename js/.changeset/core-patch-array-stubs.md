---
'@barkpark/core': minor
---

The patch builder now declares the remaining Sanity patch ops — array mutations `insert`/`append`/`prepend` and `diffMatchPatch` — as Phase-1A stubs that throw a clear "not implemented; read+set the whole field" error. With #406 (dec/setIfMissing/unset), the full Sanity patch surface now fails with migration guidance instead of "x is not a function".
