import { playwright } from '@vitest/browser-playwright'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    name: 'browser',
    include: ['tests/runtime.browser.test.ts'],
    browser: {
      enabled: true,
      // vitest 4: `browser.provider` is now a factory from
      // `@vitest/browser-playwright`, and `browser.name` is replaced by
      // `browser.instances`.
      provider: playwright(),
      instances: [{ browser: 'chromium' }],
      headless: true,
    },
  },
})
