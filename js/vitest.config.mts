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
        // NO `extends` here, on purpose. It used to extend
        // ./packages/react/vitest.config.ts, and `extends` MERGES array
        // fields — so this project inherited that config's
        // `setupFiles: ['../../test-utils/vitest.setup.ts']`, which is wrong
        // here twice over: the relative path resolves against THIS file's
        // directory (js/), not packages/react/, landing one level above the
        // repo; and the file it names imports test-utils/msw/server, i.e.
        // `msw/node`, which a real browser cannot load. Either fault aborts
        // the setup import, so this project reported
        // "Test Files 1 failed (1) / Tests no tests" on every run and the
        // browser proof never executed one assertion. An override cannot
        // undo it (`setupFiles: []` merges to the same inherited entry), so
        // the project is declared standalone. The browser suite is pure
        // renderToString and makes no network calls, so it needs no setup.
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
