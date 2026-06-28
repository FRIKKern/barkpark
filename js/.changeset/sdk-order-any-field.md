---
'@barkpark/core': minor
---

`.order()` now accepts any field, not just `_updatedAt`/`_createdAt` — e.g. `.order('title:asc')`, `.order('publishedAt:desc')` — matching the server's content-field ordering. `OrderSpec` keeps autocomplete for the system fields while admitting any `<field>:asc|desc`; the builder still validates the shape.
