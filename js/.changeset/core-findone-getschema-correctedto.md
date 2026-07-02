---
'@barkpark/core': patch
---

core: three same-package consistency fixes. `DocsBuilder.findOne()` no longer mutates the builder's shared `state` (it set `state.limit = 1` in a try/finally around a synchronous executor read) — a concurrent `Promise.all([q.findOne(), q.find()])` could make `find()` silently return a single row. It now passes a derived `{ ...state, limit: 1 }`, matching the count/page executors. `getSchema('')` (or a blank/whitespace name) now throws `BarkparkValidationError` instead of building `/v1/schemas/<ds>/`, which routes to the LIST endpoint and returns surprising data — the same fail-closed guard `deleteSchema` already uses. `SearchResult.correctedTo` is now `string | null` (was optional `string | null`); `search()` always sets it, so dropping the `undefined` case only narrows the type and existing consumers still compile.
