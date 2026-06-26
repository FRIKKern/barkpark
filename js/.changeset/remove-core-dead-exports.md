---
---

Internal: remove 5 dead exports from @barkpark/core (`isEdgeRuntime`, the deprecated
`patch`/`transaction`/`listen` aliases, and the `@internal` no-op `defineActions` stub).
None are part of the public entry (not barrel-exported, or `@internal`) and all have zero
importers — no API or behaviour change, no release.
