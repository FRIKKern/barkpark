import { defineConfig } from 'vitest/config'

// Node environment: the suite renders the PINNED artifact with
// `react-dom/server` and compares HTML strings with @barkpark/react's own
// string comparator — no DOM global is needed. Without this LOCAL config the
// package would inherit the monorepo root `test.projects` (browser/workerd) and
// crash on unresolved entries (the next-parity lesson).
//
// No `passWithNoTests`: `vitest run` must exit 1 if this file ever matches
// nothing.
export default defineConfig({
  test: {
    environment: 'node',
    // THE PREREQUISITE. `vitest.globalSetup.ts` runs
    // `scripts/prepare-pinned.mjs` before this project's suite, on EVERY
    // invocation path -- package script, root multi-project run, IDE runner --
    // because it hangs off the project's own config rather than off a
    // package.json script chain that only `pnpm --filter ... test` ever walked.
    globalSetup: ['./vitest.globalSetup.ts'],
    // The negative controls import and render the whole golden set three times
    // through three separate artifact copies.
    testTimeout: 30_000,
  },
})
