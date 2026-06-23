import { cloudflareTest } from '@cloudflare/vitest-pool-workers'
import { playwright } from '@vitest/browser-playwright'
import { defineConfig } from 'vitest/config'

// vitest 4 removed `vitest.workspace.ts` / `defineWorkspace`. Multi-project
// runs are now declared via `test.projects` on a normal root config. Each
// per-package `vitest.config.ts` is itself a project; the two extra entries
// below layer the browser + workerd runtimes on top of the react/core base
// configs (mirrors the old workspace `extends`).
export default defineConfig({
  test: {
    projects: [
      'packages/*/vitest.config.ts',
      {
        extends: './packages/react/vitest.config.ts',
        test: {
          name: 'react-browser',
          browser: {
            enabled: true,
            // vitest 4: `browser.provider` is now a factory from
            // `@vitest/browser-playwright`, and `browser.name` is replaced by
            // `browser.instances`.
            provider: playwright(),
            instances: [{ browser: 'chromium' }],
            headless: true,
          },
          include: ['packages/react/tests/**/*.browser.test.ts?(x)'],
        },
      },
      {
        extends: './packages/core/vitest.config.ts',
        // pool-workers 0.16 replaces `test.pool` + `test.poolOptions.workers`
        // with the `cloudflareTest()` Vite plugin.
        plugins: [cloudflareTest({ miniflare: { compatibilityDate: '2024-09-23' } })],
        test: {
          name: 'core-workerd',
          include: ['packages/core/tests/**/*.workerd.test.ts'],
        },
      },
    ],
  },
})
