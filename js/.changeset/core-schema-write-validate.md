---
'@barkpark/core': minor
---

`upsertSchema` and `deleteSchema` now client-side validate their inputs, matching every sibling write path in core. `upsertSchema` fast-fails with a field-tagged `BarkparkValidationError` when `name` is missing/blank (`field: 'name'`) or `fields` is not an array (`field: 'fields'`), instead of POSTing an incomplete body and paying a network round-trip for an opaque server 422. `deleteSchema('')` (or a blank/non-string name) now throws `BarkparkValidationError` (`field: 'name'`) instead of interpolating an empty segment into `/v1/schemas/:dataset/` and hitting the wrong route (404).
