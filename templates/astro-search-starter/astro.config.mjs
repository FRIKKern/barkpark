// @ts-check
import { defineConfig } from 'astro/config'
import react from '@astrojs/react'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath } from 'node:url'

// ── SUB-PATH HOSTING ────────────────────────────────────────────────────────
// The deploy engine serves the site under /sites/<slug>/ via a stripping Caddy
// handle_path — Astro's native `base` bakes that prefix into every href/asset
// URL, and the strip composes with it. The finder's <Link> + router shims read
// `import.meta.env.BASE_URL` (this `base`) so client navigation stays inside the
// sub-path too.
const rawBase = (process.env.BARKPARK_SITE_BASE || '').trim()
const base = rawBase && rawBase !== '/' ? '/' + rawBase.replace(/^\/+|\/+$/g, '') + '/' : '/'

const src = (p) => fileURLToPath(new URL(p, import.meta.url))

// ── THE FINDER, vendored VERBATIM from templates/search-starter ──────────────
// It is Next.js code. On this STATIC target we re-point its four Next module
// specifiers with Vite aliases + inline its 11 module-scope `process.env` reads
// with `define`, so ZERO vendored source is edited (charter D43). Live search's
// WebSocket URL/token are DERIVED here (D38) — WS_URL is always the API origin +
// /socket; the token gates the live path (empty → the finder rides the flat
// HTTP interceptor, both engines still work).
const apiUrl = (process.env.BARKPARK_API_URL || '').trim()
const apiOrigin = (() => {
  try {
    return apiUrl ? new URL(apiUrl).origin : ''
  } catch {
    return ''
  }
})()
const wsUrl = apiOrigin ? apiOrigin + '/socket' : ''
const token = (process.env.BARKPARK_TOKEN || '').trim()
const docType = (process.env.BARKPARK_DOC_TYPE || '').trim()

/** Inline a module-scope `process.env.X` read as a build-time string literal. */
const envStr = (v) => JSON.stringify(v ?? '')

export default defineConfig({
  output: 'static',
  base,
  integrations: [react()],
  vite: {
    plugins: [tailwindcss()],
    resolve: {
      // Order matters: the longer `@/lib` prefix is listed first.
      alias: [
        { find: '@/lib', replacement: src('./src/finder/lib') },
        { find: '@', replacement: src('./src/finder') },
        { find: 'next/link', replacement: src('./src/finder/shims/next-link.tsx') },
        { find: 'next/navigation', replacement: src('./src/finder/shims/next-navigation.tsx') },
      ],
    },
    define: {
      // 4 server-side BARKPARK_* names (config.ts / find.ts resolve their own
      // defaults over the raw value).
      'process.env.BARKPARK_DATASET': envStr(process.env.BARKPARK_DATASET),
      'process.env.BARKPARK_WORKSPACE': envStr(process.env.BARKPARK_WORKSPACE),
      'process.env.BARKPARK_PROJECT': envStr(process.env.BARKPARK_PROJECT),
      'process.env.BARKPARK_DOC_TYPE': envStr(docType),
      // 7 NEXT_PUBLIC_* names, derived to the static/browser-direct model.
      'process.env.NEXT_PUBLIC_BARKPARK_DOC_TYPES': envStr(docType), // D45: pin to built type
      'process.env.NEXT_PUBLIC_BARKPARK_WS_URL': envStr(wsUrl), // D38
      'process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN': envStr(token), // D38 (public-read; '' → dark)
      'process.env.NEXT_PUBLIC_BP_BASE_PATH': envStr(''), // interceptor matches bare /api/find
      'process.env.NEXT_PUBLIC_SITE_EYEBROW': envStr(
        process.env.NEXT_PUBLIC_SITE_EYEBROW || process.env.BARKPARK_SITE_EYEBROW,
      ),
      'process.env.NEXT_PUBLIC_SITE_TITLE': envStr(
        process.env.NEXT_PUBLIC_SITE_TITLE || process.env.BARKPARK_SITE_TITLE,
      ),
      'process.env.NEXT_PUBLIC_SITE_TAGLINE': envStr(
        process.env.NEXT_PUBLIC_SITE_TAGLINE || process.env.BARKPARK_SITE_TAGLINE,
      ),
      // Theme identity default (used by future themed variants; harmless now).
      'process.env.NEXT_PUBLIC_BARKPARK_THEME': envStr(process.env.BARKPARK_THEME),
    },
  },
})
