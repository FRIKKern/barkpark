<!-- doc-tier: human | canonical-for: codegen-package | budget: 300tok -->
# @barkpark/codegen

Schema → typed TypeScript codegen (preview.0). `barkpark generate` fetches `/v1/schemas/:dataset` and emits a single `barkpark.types.ts` — one interface per schema (all v2 field types) plus a `BarkparkTypeMap`. `--from <file>` (alias `--schema`) reads a committed schema-envelope JSON network-free — the path the CI drift gate runs. Pair `BarkparkTypeMap` with `@barkpark/core`'s `typedClient<BarkparkTypeMap>` to narrow `doc`/`docs` by type (mutate/listen stay unnarrowed by design). Also exports `defineConfig`, `buildSchemaPath`, `fetchSchema`, `generateTypes`; `schema-path <dataset>` **prints** the introspection path.

Schema fetches default to the flat `/v1/schemas/:dataset` path. Set both `workspace` and `project` (config or `--workspace`/`--project` CLI flags) to use the scoped `/w/:workspace/p/:project/v1/schemas/:dataset` path; omit them for the flat back-compat path.

