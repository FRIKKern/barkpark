import { defineConfig } from 'vitest/config'

// Node environment: the suite reads the ALREADY-BUILT `dist/**` HTML off disk and
// parses it with happy-dom's own DOMParser/document — it does NOT need a global DOM
// environment, and it deliberately does NOT pull the monorepo msw setup (no network).
export default defineConfig({
  test: {
    environment: 'node',
  },
})
