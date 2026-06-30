---
'@barkpark/groq': patch
---

Fix the 1.0 filter-DSL example in the deferred `@barkpark/groq` stub's docs. It referenced a non-existent API on three counts — `client.queryByType('post').where('status', '=', 'published').fetch()` — none of `queryByType`, the `'='` operator, or `.fetch()` exist. Corrected to the real, tested surface: `client.docs('post').where('status', 'eq', 'published').find()`.
