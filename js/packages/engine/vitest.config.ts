import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    name: '@barkpark/engine',
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    // The integration test boots a real release; a first boot creates every table.
    testTimeout: 15_000,
  },
})
