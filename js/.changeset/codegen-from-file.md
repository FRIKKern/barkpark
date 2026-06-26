---
"@barkpark/codegen": minor
---

Add a `--from <file>` option (alias `--schema`) to `barkpark generate`: read and zod-parse a
local schema-envelope JSON file instead of fetching `/v1/schemas/:dataset`. This is the
network-free path the CI drift gate runs from a committed schema fixture (GitHub Actions cannot
reach the live API). The fetch path stays the default; `--from` only needs `--dataset` (for the
banner) and `--output`.

Also emit `BarkparkTypeMap` as a `type` alias rather than an `interface`, so it satisfies the
`TMap extends Record<string, object>` constraint on `@barkpark/core`'s `typedClient<TMap>` — an
interface lacks the implicit index signature that constraint requires, so
`typedClient<BarkparkTypeMap>` was previously a compile error. The generated module is otherwise
byte-identical.
