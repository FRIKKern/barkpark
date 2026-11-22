import { defineConfig } from 'vitest/config'
import { FAST_TESTS } from './tests/fast-tests.mjs'

// Fast tests only: no browser. The browser proof is `pnpm run check`.
export default defineConfig({
  test: {
    name: '@barkpark/barkui',
    environment: 'node',
    include: FAST_TESTS,
  },
})
