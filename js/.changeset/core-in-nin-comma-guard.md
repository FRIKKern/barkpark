---
'@barkpark/core': patch
---

`in()`/`nin()` now fail closed with a validation error when a candidate value contains a comma — previously the value silently split into multiple candidates on the wire, returning wrong results. The query wire format joins candidates with `,` and the server splits on it, so `.in('sku', ['A,B'])` queried `sku IN ('A','B')` instead of the literal `'A,B'` (and `.nin` over-excluded the same way). Date candidates are exempt (they serialize to comma-free ISO strings). Mirrors the sibling comma guard in `normalizeFieldList`.
