---
'@barkpark/core': patch
---

Clarify `.expand()` / `doc({ expand })` docs: server-side expansion resolves only **single** reference fields (value = a plain id string), depth 1 — arrays of references and `{_ref}`-object values are not inlined. (Corrects the earlier examples that implied an array field like `tags` would expand.)
