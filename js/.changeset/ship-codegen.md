---
"@barkpark/codegen": patch
---

docs: @barkpark/codegen ships schema→typed-client generation (un-defer)

The package README and the js/ package map described codegen as a not-built
boundary (`schema-path` print-only, no fetch, no `barkpark.types.ts`, no
`typedClient`). That is stale: `barkpark generate` fetches `/v1/schemas/:dataset`
and emits `barkpark.types.ts` (interfaces + `BarkparkTypeMap`), `--from`/`--schema`
reads a committed envelope network-free to power the CI drift gate, and the emitted
`BarkparkTypeMap` pairs with `@barkpark/core`'s `typedClient<TMap>` to narrow
`doc`/`docs`. Doc-truth only — no code change. The `codegen` row is removed from
`docs/decisions/deferred.md` (no longer deferred). Note: `typedClient` narrows
`doc`/`docs` only; mutate (transaction/create/patch) and `listen` stay unnarrowed.
