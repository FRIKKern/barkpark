---
'@barkpark/codegen': patch
---

`fetchSchema` and `buildSchemaPath` now throw when exactly one of `workspace` /
`project` is supplied, instead of silently falling back to the flat
`/v1/schemas/<dataset>` path.

This closes a guard that failed **open**. The previous check was
`if (workspace && project)` inside `buildSchemaPath`: a half-set pair did not
error, it quietly dropped the scope. So a developer who scoped `fetchSchema` to a
workspace but forgot the project (or vice versa) sent their bearer token to an
endpoint they never asked for and generated `barkpark.types.ts` from the wrong
tenant's content model — no error, no warning, just confident wrong output. The
earlier fix guarded only the CLI (`resolveConfig` and `schema-path`), while
`fetchSchema`, exported from the package root, stayed unguarded.

The guard now lives beside `buildSchemaPath`, the chokepoint every scoped-URL
entry point runs through, so the CLI, `fetchSchema`, and direct `buildSchemaPath`
callers are all covered — and it is a runtime check, because this package ships
to plain-JS callers whose types cannot warn them. An empty-string half is
refused too: `''` is falsy, so the old `&&` swallowed it the same way.

`assertScopedPair` is now exported. Its message is unified with the identical
guard in `@barkpark/core` — `workspace and project must be set together (both =
scoped routes, neither = flat /v1)` — replacing the CLI's previous
`workspace and project must be provided together` wording, so one invariant
reads one way across the SDK.

Passing both slugs, or neither, is unchanged.
