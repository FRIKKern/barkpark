---
'@barkpark/nextjs': patch
---

Document `barkparkFetch`'s `query` option and drop a stale TODO. The `query?: BuilderState` field already uses the unified `BuilderState` type exported by `@barkpark/core` (the TODO's precondition was met); its JSDoc now shows how to build the state with `makeFilterExpression`.
