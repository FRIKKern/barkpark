# @barkpark/codegen

Schema-path helpers for codegen tooling (preview.0). Exports `defineConfig` (config helper) and `buildSchemaPath`, and ships a `barkpark` CLI whose `schema-path <dataset>` subcommand **prints** the schema-introspection path. It does NOT yet fetch the schema endpoint, does NOT emit `barkpark.types.ts`, and does NOT produce a `typedClient` — that helper is exported from `@barkpark/core` (`core/src/index.ts:63`).

Schema fetches default to the flat `/v1/schemas/:dataset` path. Set both `workspace` and `project` (config or `--workspace`/`--project` CLI flags) to use the scoped `/w/:workspace/p/:project/v1/schemas/:dataset` path; omit them for the flat back-compat path.

See `docs/adr/` for architectural decision records.
