---
'@barkpark/core': patch
---

Input validation hardening (fail-closed behavior changes):

- `filter()` builder: `.in(field, [])` / `.nin(field, [])` (and raw `.where(field, 'in'|'nin', [])`) now throw `BarkparkValidationError`. An empty candidate list ships `filter[field][in]=`, an ambiguous match-nothing query that is almost always an upstream bug — pass at least one candidate or drop the filter.
- `getDoc(type, id, { expand, fields })` now runs `expand`/`fields` through the same normalizer the builder's `expand()`/`select()` use: it trims each name and drops empties (so `fields: ['title', '', 'slug']` sends `fields=title,slug` instead of the phantom-field `fields=title,,slug`), rejects a comma inside a name, and throws on an empty list (`{ fields: [] }` previously shipped a silent no-op). `undefined` still omits the param.
- `searchAssets()` `tags`/`facets` array inputs are trimmed with empties dropped; a cleaned-empty list omits the param (values, not a projection — no throw).
