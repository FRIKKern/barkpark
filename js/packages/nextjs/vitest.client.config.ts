import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    name: 'client',
    environment: 'jsdom',
    include: ['tests/**/*.client.test.ts', 'tests/**/*.client.test.tsx'],
    passWithNoTests: true,
    setupFiles: ['../../test-utils/vitest.setup.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'],
      include: ['src/client/**'],
    },
  },
})
