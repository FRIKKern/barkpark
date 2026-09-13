---
---

Empty changeset: test-only. Adds `js/packages/core/tests/manifest-parity.test.ts`, the SDK ↔ capabilities-manifest drift tripwire, plus its shared fixture at `api/test/support/fixtures/sdk-capabilities-parity.json` and the Elixir producer-side lock that reads it. No `src/**` file changes, so `@barkpark/core` ships exactly the same runtime and needs no version bump.
