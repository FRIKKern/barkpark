# @barkpark/codegen

Schema introspection + typed-client codegen. Ships the `barkpark` CLI that reads the schema endpoint and emits `barkpark.types.ts` plus a bound `typedClient` factory.

Schema fetches default to the flat `/v1/schemas/:dataset` path. Set both `workspace` and `project` (config or `--workspace`/`--project` CLI flags) to use the scoped `/w/:workspace/p/:project/v1/schemas/:dataset` path; omit them for the flat back-compat path.

See **ADR-006** (two-step typedClient codegen).
