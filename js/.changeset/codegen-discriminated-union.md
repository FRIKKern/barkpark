---
'@barkpark/codegen': minor
---

Generated types now include a `BarkparkAnyDocument` discriminated union of every document type, and each interface pins its `_type` to the schema-name literal (e.g. `Post['_type']` is `'post'`, not `string`). This lets you narrow a mixed/unknown document by `_type` with full type safety (`if (doc._type === 'post')` narrows `doc` to `Post`) — Sanity-style typed `_type` discrimination. Backward-compatible: the literal is a narrowing of the previously inherited `string`.
