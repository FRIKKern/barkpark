---
"@barkpark/core": patch
---

Widen DocsBuilder eq/neq/in/nin/has to accept `Date` (the runtime encoder already ISO-normalizes it), matching the gt/gte/lt/lte siblings and `where()`.
