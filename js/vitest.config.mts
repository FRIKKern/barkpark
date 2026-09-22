import { globSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { cloudflareTest } from '@cloudflare/vitest-pool-workers'
import { playwright } from '@vitest/browser-playwright'
import { defineConfig } from 'vitest/config'

// vitest 4 removed `vitest.workspace.ts` / `defineWorkspace`. Multi-project
// runs are now declared via `test.projects` on a normal root config. Each
// per-package `vitest.config.ts` is itself a project (but see the wrapper note
// below); the two extra entries at the bottom layer the browser + workerd
// runtimes on top of the react/core base configs (mirrors the old workspace
// `extends`).

const here = import.meta.dirname

// DERIVE THE PACKAGE PROJECTS; DO NOT COMPOSE A WRAPPER AS ONE PROJECT.
//
// `packages/*/vitest.config.ts` is USUALLY a leaf project. It is not always.
// A package may use that file as a WRAPPER that declares its own
// `test.projects` split — several configs, each with its own `environment`
// and `include` — because one environment cannot serve all of its tests.
// `@barkpark/nextjs` is the live case: server (node) / client (jsdom) /
// browser (real chromium), which its own `test` script runs as three
// SEPARATE `vitest run --project=` commands.
//
// Listing such a wrapper here flattens that split. Vitest does not recurse
// into a project's own `projects`; it takes the wrapper as a single project
// with default `include`, so all of the package's test files execute in ONE
// environment. Measured on a clean tree before this change:
//
//   $ npx vitest run --project=@barkpark/nextjs
//    Test Files  15 failed | 10 passed (25)
//         Tests  7 failed | 142 passed | 1 skipped (150)
//   ReferenceError: window is not defined   (tests/live.client.test.tsx, ...)
//
// Those reds were not @barkpark/nextjs's bug — its own gate passes all three
// projects — they were this file's composition dropping a split the package
// deliberately makes. So: read each package config, and where it declares its
// own `test.projects`, register THOSE instead of the wrapper. Nothing below
// names a package; a package that adopts (or drops) a split is handled on its
// next run, and nothing here needs editing.
const packageProjects: string[] = []
for (const rel of globSync('packages/*/vitest.config.ts', { cwd: here }).sort()) {
  const abs = resolve(here, rel)
  const mod = await import(pathToFileURL(abs).href)
  const nested = mod?.default?.test?.projects
  if (!Array.isArray(nested) || nested.length === 0) {
    packageProjects.push(abs)
    continue
  }
  for (const child of nested) {
    if (typeof child !== 'string') {
      // An inline project object inside a package config cannot be re-rooted
      // safely (its relative paths resolve against ITS root, not ours). Refuse
      // loudly rather than silently drop a project — a dark project is the
      // exact failure js/scripts/check-vitest-projects.mjs exists to catch.
      throw new Error(
        `${rel} declares a non-string entry in test.projects; the root config can only ` +
          're-register sub-config PATHS. Give the project its own config file.',
      )
    }
    packageProjects.push(resolve(dirname(abs), child))
  }
}

export default defineConfig({
  test: {
    projects: [
      ...packageProjects,
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
