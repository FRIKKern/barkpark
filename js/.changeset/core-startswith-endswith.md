---
'@barkpark/core': minor
---

New string filter operators `startsWith` / `endsWith` — `.startsWith(field, value)` / `.endsWith(field, value)` (and via `.where`). Anchored prefix/suffix matching (case-insensitive, like `contains`), with LIKE wildcards escaped. Matches Strapi's `$startsWith` / `$endsWith`.
