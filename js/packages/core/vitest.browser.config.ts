import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    name: 'browser',
    include: ['tests/runtime.browser.test.ts'],
    browser: {
      enabled: true,
      name: 'chromium',
      provider: 'playwright',
      headless: true,
    },
  },
})
