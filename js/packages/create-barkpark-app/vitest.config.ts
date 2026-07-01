import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    name: 'create-barkpark-app',
    environment: 'node',
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov', 'json'],
      include: ['src/**'],
    },
  },
})
