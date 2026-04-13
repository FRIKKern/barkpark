import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globals: false,
    environment: 'node',
    testTimeout: 10_000,
    hookTimeout: 20_000,
  },
})
