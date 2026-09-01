---
---

Empty changeset: gate configuration only, no published code changes and no version bump.

`turbo run lint` and `turbo run typecheck` printed `<NONEXISTENT>` and exited 0 for five packages that declared neither script (`astro-decoy`, `astro-parity`, `blog-hydration-parity`, `media-parity`, `next-parity` — all `private: true`), so 21 files were gated by nothing. `@barkpark/codegen`'s and `create-barkpark-app`'s changes are script + tsconfig only: codegen's `lint` now reaches its SINGULAR `test/` dir (9 files linted → 21) and create-barkpark-app's reaches `tests/` (9 → 20, and 9 → 22 typechecked). Neither package's `dist` output changes — verified by rebuilding create-barkpark-app after the `rootDir` widening and diffing the emitted file list.

Also widens `js/turbo.json` cache inputs to the files the tasks actually execute (`test/**`, `vitest*.config.*`, `$TURBO_ROOT$/test-utils/**`, `$TURBO_ROOT$/scripts/post-build-dts.mjs`).
