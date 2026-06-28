---
'@barkpark/core': patch
---

Update `.expand()` / `doc({ expand })` docs: the server now also inlines `arrayOf`-of-reference fields (e.g. `tags`), not just single refs. Each element may be a plain id string or a `{_ref}` object.
