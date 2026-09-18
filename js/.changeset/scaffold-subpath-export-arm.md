---
---

Empty changeset: test-only. Adds `tests/template-subpath-exports.test.ts`, which asserts every `@barkpark/*` subpath a starter template imports is a key in that package's `exports` map, plus an opt-in (`CHECK_PUBLISHED_EXPORTS=1`) probe that re-measures the same question against the published registry manifests. `create-barkpark-app` publishes only `dist`, `templates`, `README.md` and `LICENSE`, so nothing in the released artifact changes. No package's published bundle grows.
