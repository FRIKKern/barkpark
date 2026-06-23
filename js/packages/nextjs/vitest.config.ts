import { defineConfig } from 'vitest/config'

// vitest 4 removed `vitest.workspace.ts`; workspaces are now expressed as
// `test.projects` on the root config (vitest 3+ API). The two project
// definitions still live in their own files so `--project=server` /
// `--project=client` keep working.
export default defineConfig({
  test: {
    projects: ['./vitest.server.config.ts', './vitest.client.config.ts'],
  },
})
