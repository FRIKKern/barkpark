import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    name: 'server',
    environment: 'node',
    include: ['tests/**/*.test.ts', '!tests/**/*.client.test.ts'],
    setupFiles: ['./tests/setup.server.ts', '../../test-utils/vitest.setup.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'],
      include: ['src/**', '!src/client/**'],
    },
  },
})
