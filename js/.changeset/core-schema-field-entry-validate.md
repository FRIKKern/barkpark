---
'@barkpark/core': patch
---

`client.upsertSchema()` now validates each field entry client-side, not just that `fields` is an array. A field that is not a non-null object, or is missing a non-empty string `name` or `type` (e.g. `fields: [{ type: 'string' }]`, `fields: ['title']`, `fields: [{ name: 'title' }]`), now fails closed with a self-explaining `BarkparkValidationError` instead of sailing into an opaque server 422 — matching the fail-closed posture of the other write guards. The valid-input path is unchanged.
