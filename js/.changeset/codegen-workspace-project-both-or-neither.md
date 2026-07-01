---
"@barkpark/codegen": patch
---

`barkpark generate` now errors when only one of `--workspace` / `--project` is
supplied instead of silently mis-scoping. The two flags are the halves of a
scoped schema path; passing just one previously fell back to the flat
`/v1/schemas/<dataset>` path and emitted types for the wrong (unscoped) content
model with no warning. `resolveConfig` now enforces both-or-neither and throws
`workspace and project must be provided together`.
