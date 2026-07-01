---
'@barkpark/core': patch
---

`SearchOptions.engine` is now an open union (`'postgres' | 'indx' | (string & {})`) so a newly-added server search engine isn't a false compile error; autocomplete for the known engines (`postgres`/`indx`) is preserved. The value was already passed through to the `engine` query param verbatim at runtime — only the static type was over-constrained.
