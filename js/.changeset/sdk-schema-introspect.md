---
'@barkpark/core': minor
---

Add schema introspection: `bp.schemas()` (all schemas) and `bp.getSchema(name)` (one, or `null`). The server already serializes schemas *for the SDK* (`GET /v1/schemas`), useful for dynamic/generic UIs that render fields from the schema. Exports the `BarkparkSchema` type.
