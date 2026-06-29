---
'@barkpark/core': minor
---

`.eq(field, null)` / `.neq(field, null)` now do proper null/absence filtering (server `IS NULL` / `IS NOT NULL`) instead of silently matching the empty string. So `eq('category', null)` finds documents where the field is null or absent — matching Strapi's `$null` / Sanity's `== null`. Nested paths supported.
