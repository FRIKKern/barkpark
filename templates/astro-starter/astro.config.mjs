// @ts-check
import { defineConfig } from 'astro/config'

/**
 * The path this site is served under, behind the shared Caddy front. The
 * site-spawner deploy engine serves every spawned site at a PATH under the
 * content FQDN (the "PATH-under-FQDN" finish line), so the built asset URLs
 * must be prefixed with `/sites/<slug>/`.
 *
 * Parameterized via `BARKPARK_SITE_BASE` so the same template, unchanged, ships
 * under any slug. Astro requires a leading AND trailing slash on `base`; we
 * normalize whatever the env carries so a bare slug or a missing slash still
 * works.
 */
function resolveBase() {
  const raw = (process.env.BARKPARK_SITE_BASE || '/sites/astro-starter/').trim()
  const withLead = raw.startsWith('/') ? raw : `/${raw}`
  return withLead.endsWith('/') ? withLead : `${withLead}/`
}

// https://astro.build/config
export default defineConfig({
  // Static output — the whole point of the spawner: reproducible, isolated
  // builds that produce plain HTML the deploy engine can health-gate and
  // atomically switch. No SSR runtime lives next to Phoenix.
  output: 'static',
  base: resolveBase(),
  // `BARKPARK_SITE_ORIGIN` (optional) is the public origin the site is served
  // from; only used to make absolute canonical/OG URLs. Falls back to a
  // localhost placeholder that is never emitted into content markers.
  site: process.env.BARKPARK_SITE_ORIGIN || 'http://localhost:4321',
  build: {
    // Keep asset URLs stable and predictable under the base prefix.
    assetsPrefix: undefined,
  },
})
