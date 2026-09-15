---
---

No release. Dev-tooling only: adds `js/packages/react/scripts/bundle-census.mjs`
(a per-source-file byte census of the bundles `.size-limit.json` measures) plus
the pinned `esbuild` devDependency it needs. No file under `src/` changed, so no
shipped behaviour changed. `scripts/` is excluded from the published tarball by
the existing `files` allowlist — `npm pack --dry-run` lists 61 files, all
`dist/**` plus `README.md` and `package.json`, and none under `scripts/`.
