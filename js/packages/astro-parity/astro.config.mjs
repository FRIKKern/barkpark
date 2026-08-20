// @ts-check
import { defineConfig } from 'astro/config'

/**
 * Wave-2 render-path-unification parity surface (charter D16-D23).
 *
 * `output: 'static'` — a real Astro STATIC build. The single page SSRs every
 * pd-golden block through `@barkpark/react`'s `renderPortableDocument` via
 * `set:html` with NO client directive, so the emitted `dist/**.html` is the
 * exact Phoenix-faithful markup with ZERO shipped JS. There are deliberately
 * NO integrations here (no `@astrojs/react`) — an island framework would be the
 * thing that ships `_astro/*.js`, which the parity guard proves is empty (D22).
 *
 * `compressHTML` is left at its default (true): whitespace-collapsed output is
 * harmless to the DOM-shape comparator (it is whitespace-insensitive) and keeps
 * the built HTML honest to what a real Astro consumer would ship.
 */
export default defineConfig({
  output: 'static',
  // No `site`/`base` — this is a parity harness, not a hosted site; default
  // root-relative asset URLs keep the built HTML minimal.
  devToolbar: { enabled: false },
})
