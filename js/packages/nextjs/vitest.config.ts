import { defineConfig } from 'vitest/config'

// vitest 4 removed `vitest.workspace.ts`; workspaces are now expressed as
// `test.projects` on the root config (vitest 3+ API). The project
// definitions still live in their own files so `--project=server` /
// `--project=client` / `--project=browser` keep working.
//
// `browser` is the third project: a real headless chromium. It is NOT a
// side-script — `pnpm test` runs it, so a browser-only regression gates.
export default defineConfig({
  test: {
    projects: [
      './vitest.server.config.ts',
      './vitest.client.config.ts',
      './vitest.browser.config.ts',
    ],
  },
})
