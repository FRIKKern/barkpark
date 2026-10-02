---
'@barkpark/nextjs': patch
---

Internal (test-only, zero shipped bytes): the `cache: "no-store"` + `next.tags` contract gate scanned only `dist/server.mjs`. tsup builds this package with `splitting: true` over nine entry points, so esbuild hoists code shared between entries into sibling `chunk-*.{mjs,cjs}` files that `server.mjs` merely imports — a forbidden pair planted in a shared module (`src/tag-prefix.ts`, used by server + actions + revalidate) landed in `dist/chunk-*.mjs`/`.cjs` and the gate stayed green. The gate now derives its artifact set by globbing every emitted `.mjs`/`.cjs`/`.js` under `dist/`, names the offending artifact in the failure, and carries a control asserting the glob is non-empty so it can never pass vacuously.
