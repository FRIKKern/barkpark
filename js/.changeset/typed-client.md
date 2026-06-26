---
"@barkpark/core": minor
---

Add `TypedClient<TMap>` and re-type `typedClient` so a generated schema TypeMap narrows `doc`/`docs`:
`typedClient<BarkparkTypeMap>(createClient(cfg)).doc('post', id)` now infers `Post | null`, and an
unknown type (`doc('psot', …)`) is a compile error. Runtime is unchanged (the identity). Pairs with
`@barkpark/codegen`'s generated `barkpark.types.ts`. The previously `@internal` `typedClient<C>`
identity helper (no real callers) is promoted to this public, schema-aware seam.
