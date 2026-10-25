---
'@barkpark/core': minor
---

Add the `neqOrMissing` filter operator to `FilterOp` / `.where()`: GROQ's `!=`, where a document without the field (or with null) counts as not equal. `neq` keeps leaving those documents out. Matches the server op in `/v1/data/query`.
