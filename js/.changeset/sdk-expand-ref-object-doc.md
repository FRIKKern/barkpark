---
'@barkpark/core': patch
---

Update `.expand()` / `doc({ expand })` docs to match the server: a single reference field's value may now be a plain id string **or** a `{_ref}` object (both inline). Arrays of references are still not inlined.
