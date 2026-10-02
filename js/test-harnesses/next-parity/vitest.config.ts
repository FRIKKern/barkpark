import { defineConfig } from 'vitest/config'

// Node environment (REQUIRED, charter D32): the suite reads the ALREADY-BUILT
// `out/**` static-export HTML off disk and parses it with happy-dom's own
// DOMParser — it needs no global DOM environment. Without this LOCAL config the
// package would inherit the monorepo root `test.projects` (browser/workerd) and
// crash on unresolved entries.
export default defineConfig({
  test: {
    environment: 'node',
  },
})
