---
'@barkpark/core': minor
---

`patch().append(selector, items)` and `patch().prepend(selector, items)` are now implemented (Phase-1B). They extend a top-level array field from the end / front — `client.patch(id).append('tags[-1]', ['new']).commit()` — composing with the other patch ops. The selector resolves to its field (`'tags'` or `'tags[-1]'`); nested/dotted selectors and system fields are rejected, `items` must be an array. The server creates a missing field and leaves a non-array value untouched. Requires the server's `patch.append`/`prepend` support (shipped in #507). `insert`/`diffMatchPatch` remain Phase-1A throws.
