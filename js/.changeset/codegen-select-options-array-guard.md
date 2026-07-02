---
'@barkpark/codegen': patch
---

`generate`: guard a `select` field's `options` with `Array.isArray` instead of a truthy `?? []` fallback (#865). A malformed schema whose `options` is a bare **string** (truthy and iterable) made `for...of` walk it character-by-character, emitting a garbage char union like `'a' | 'b' | 'c'` instead of the intended enum. A non-array `options` now falls back to the plain `string` type. Well-formed schemas from the server (always an array) are unaffected.
