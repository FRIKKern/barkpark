// @ts-check
import { defineConfig } from 'astro/config'
import react from '@astrojs/react'

// SUB-PATH HOSTING: the deploy engine serves the site under /sites/<slug>/ via
// a stripping Caddy handle_path — Astro's native `base` bakes that prefix into
// every href/asset URL, and the strip composes with it: a request for
// /sites/<slug>/assets/x.css strips to dist/assets/x.css. (The node/basePath
// marker dance search-starter needs does NOT apply to the static target.)
const rawBase = (process.env.BARKPARK_SITE_BASE || '').trim()
const base = rawBase && rawBase !== '/' ? '/' + rawBase.replace(/^\/+|\/+$/g, '') + '/' : '/'

export default defineConfig({
  output: 'static',
  base,
  integrations: [react()],
})
