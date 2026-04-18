import { defineWorkspace } from 'vitest/config'

export default defineWorkspace([
  'packages/*/vitest.config.ts',
  {
    extends: './packages/react/vitest.config.ts',
    test: {
      name: 'react-browser',
      browser: {
        enabled: true,
        provider: 'playwright',
        name: 'chromium',
        headless: true,
      },
      include: ['packages/react/tests/**/*.browser.test.ts?(x)'],
    },
  },
  {
    extends: './packages/core/vitest.config.ts',
    test: {
      name: 'core-workerd',
      pool: '@cloudflare/vitest-pool-workers',
      poolOptions: {
        workers: {
          miniflare: { compatibilityDate: '2024-09-23' },
        },
      },
      include: ['packages/core/tests/**/*.workerd.test.ts'],
    },
  },
])
