import { cloudflareTest } from '@cloudflare/vitest-pool-workers'
import { defineConfig } from 'vitest/config'

// @cloudflare/vitest-pool-workers 0.16 (vitest 4) dropped the `/config`
// `defineWorkersConfig` + `test.poolOptions.workers` shape. The runtime is now
// wired in as a Vite plugin via `cloudflareTest(<the old workers options>)`.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.toml' },
      miniflare: {
        compatibilityDate: '2024-09-23',
        compatibilityFlags: ['nodejs_compat'],
      },
    }),
  ],
  test: {
    name: 'workerd',
    include: ['tests/runtime.workerd.test.ts'],
  },
})
