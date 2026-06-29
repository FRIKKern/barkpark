---
'@barkpark/react': patch
---

`PortableText` no longer throws when a block is missing its `children` array (or has a non-array value there) — a malformed block now renders empty instead of crashing the whole render. Loosely-typed query/migration data can omit `children` even though the type marks it required.
