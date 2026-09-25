// @ts-check
import { defineConfig } from 'astro/config'
import react from '@astrojs/react'

/**
 * The DECOY (charter D18): a real Astro static site WITH the React island
 * integration and a `client:load` component. Its whole job is to make the two
 * zero-JS checks that @barkpark/astro-parity relies on turn RED — proving those
 * checks are non-vacuous (a green there means "genuinely no JS", not "the check
 * never fires"). This package carries `@astrojs/react` on purpose and is kept
 * SEPARATE from astro-parity so the integration never leaks into the parity path.
 */
export default defineConfig({
  output: 'static',
  integrations: [react()],
  devToolbar: { enabled: false },
})
