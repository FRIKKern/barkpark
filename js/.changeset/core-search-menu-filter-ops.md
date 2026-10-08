---
'@barkpark/core': minor
---

Add the search-menu filter operators to `FilterOp` / `.where()`: `notContains` (a document without the field matches), `nhas` (the array lacks the value, `_ref` or scalar), and the array-length family `countEq`, `countNeq`, `countGt`, `countGte`, `countLt`, `countLte` (integer value; no array counts 0). Matches the server ops in `/v1/data/query`. A document that references an id anywhere is `filter[_references]=<id>` (`.where('_references', 'eq', id)`).
