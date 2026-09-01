---
---

Test-only: gate `@barkpark/core`'s export surface — every `export` under `src/**` must be re-exported from `src/index.ts` or carry an `@internal` marker naming a reason. Adds the test plus `@internal` reasons on the 32 currently-unreachable exports; four of those reasons record that the symbol SHOULD be exported (it is mirrored by hand in `@barkpark/nextjs`) and that exporting it is deferred to task-296d7e0028c7e7e0. Comments and a test only — no runtime change, no export added or removed, bundle bytes unchanged, no release.
