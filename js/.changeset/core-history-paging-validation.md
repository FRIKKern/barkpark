---
'@barkpark/core': patch
---

core: `getHistory()` now validates `limit` client-side via `assertPaging`. An invalid `limit` (negative, non-integer, or `NaN`) throws a `BarkparkValidationError` synchronously instead of shipping a garbage query string (`?limit=NaN`) that the server answers with an opaque 400/500 — matching the guard already applied by the other paginated reads.
