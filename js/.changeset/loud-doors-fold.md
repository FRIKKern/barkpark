---
---

No release. Dev-tooling only: adds `js/packages/react/scripts/bundle-census.mjs`,
a per-source-file byte census of the bundles `.size-limit.json` measures. It
declares NO new dependency — it resolves esbuild through the existing
`@size-limit/preset-small-lib` devDep, so it runs the exact instance size-limit
runs and cannot drift from it.

No file under `src/` changed, so no shipped behaviour changed. The only edit to
the published `package.json` is one `scripts.census` entry. `scripts/` itself is
excluded from the published tarball by the existing `files` allowlist —
`npm pack --dry-run --json` lists 61 files, all `dist/**` plus `README.md` and
`package.json`, none under `scripts/`.
