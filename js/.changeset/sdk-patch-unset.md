---
'@barkpark/core': minor
---

`patch().unset(keys)` is now implemented (Phase-1B). It removes content fields from a document and composes with `set()` in one commit: `client.patch(id).set({ a: 1 }).unset(['draft', 'legacy']).commit()`. An unset-only patch no longer requires a preceding `set()`. Keys are validated (must be a string array; system fields are rejected client-side, and the server also protects promoted/system fields). Requires the server's `patch.unset` support (shipped in #477).
