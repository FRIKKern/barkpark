import { defineConfig } from 'vitest/config'

// Node environment: reads the already-built dist/** off disk. No msw, no network.
export default defineConfig({
  test: {
    environment: 'node',
  },
})
