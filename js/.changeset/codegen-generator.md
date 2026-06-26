---
"@barkpark/codegen": minor
---

Implement the schema→TypeScript generator. `barkpark generate` now fetches `/v1/schemas/:dataset`
and emits a single `barkpark.types.ts` — one `interface` per schema (extending a self-declared
`BarkparkSystemFields` with NO index signature, so unknown fields are compile errors) plus a
`BarkparkTypeMap`. Recursive field mapping covers all 17 schema field types (primitives, `select`
→ string-literal union, `reference`/`array`/`arrayOf`/`composite` structural, `richText`/
`localizedText`/`object` special), deterministically sorted and prettier-formatted with a
schema-hash banner. The emitted file imports nothing from `@barkpark/core`. Adds `fetchSchema`,
`generateTypes`, the zod-validated envelope, and a `generate [--watch]` CLI command. NOTE: the
config shape changed from `{ input }` to `{ dataset, apiUrl, token?, output, workspace?, project? }`
(preview-stage breaking change).
