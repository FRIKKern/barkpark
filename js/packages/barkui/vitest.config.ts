import { defineConfig } from 'vitest/config'

// Fast tests only: no browser. The browser proof is `pnpm run check`.
export default defineConfig({
  test: {
    name: '@barkpark/barkui',
    environment: 'node',
    include: ['tests/**/*.test.mjs'],
  },
})
