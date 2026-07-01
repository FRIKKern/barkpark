---
'@barkpark/core': patch
---

core: `getGraph()` now validates `depth` client-side. A `depth` that is not an integer in `1..5` (e.g. `0`, `6`, `2.5`, or `NaN`) throws a `BarkparkValidationError` synchronously instead of shipping a garbage query string (`?depth=NaN`) that the server answers with an opaque 400/500 or a silently-clamped result — matching the guard already applied by the other numeric reads (`assertPaging`).
</content>
</invoke>
