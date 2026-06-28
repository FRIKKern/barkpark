---
'@barkpark/core': patch
---

Document that query-builder filters match schema fields, not the system `_id`/`_type` — use `bp.doc(type, id)` to fetch by id (a `.eq('_id', …)` filter silently matches nothing).
