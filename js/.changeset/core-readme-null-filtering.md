---
'@barkpark/core': patch
---

Docs: document null/absence filtering (`.eq(field, null)` / `.neq(field, null)` → `IS NULL` / `IS NOT NULL`) in the README operators section — the capability shipped in the null-filtering change but wasn't shown, and it isn't self-evident from the operator list.
