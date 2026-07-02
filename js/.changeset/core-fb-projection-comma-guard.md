---
'@barkpark/core': patch
---

`filter()` builder: `expand()` and `select()` now reject a field name containing a comma. Field names are joined with `,` into the `expand`/`fields` query params, so a comma inside a name (e.g. `select("title,secret")`) would silently split into multiple projected fields — a corrupted / over-broad projection. It now throws `BarkparkValidationError` with a clear message pointing to the array form.
