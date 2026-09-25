import { playwright } from '@vitest/browser-playwright'
import { defineConfig } from 'vitest/config'

// BROWSER MODE IS THE DEFAULT (charter D18/D19). This IS `vitest.config.ts`, so
// the package's plain `test: "vitest run"` script launches a real headless
// Playwright chromium — the ONLY runtime where the two media blocks actually
// hydrate: mermaid needs real layout to emit a non-empty SVG, and
// asciinema-player throws on happy-dom's missing 2D-canvas context.
//
// This is deliberately NOT a `test:browser` side-script (the trap core fell
// into): turbo + CI run only the default `test` task, so a browser proof parked
// behind a side-script never gates. Because this file is named `vitest.config.ts`
// it is already covered by the root turbo `test` task inputs, so a config change
// busts the cache instead of serving a stale green.
export default defineConfig({
  // `hydratePortableDoc` reaches `mermaid` and `asciinema-player` through lazy
  // `import()`s, so Vite only discovers them mid-run — on a cold `.vite` cache
  // it re-optimizes and RELOADS the page, which aborts the in-flight test module
  // ("Vite unexpectedly reloaded a test" → "Failed to fetch dynamically imported
  // module"). Pre-declaring them here (vitest's own recommended fix) primes the
  // optimizer before the first test, so a fresh CI checkout is deterministic.
  optimizeDeps: {
    include: ['mermaid', 'asciinema-player'],
  },
  test: {
    name: 'media-parity',
    include: ['tests/**/*.browser.test.ts'],
    browser: {
      enabled: true,
      // vitest 4: `browser.provider` is a factory from
      // `@vitest/browser-playwright`; `browser.instances` replaces `browser.name`.
      provider: playwright(),
      instances: [{ browser: 'chromium' }],
      headless: true,
    },
  },
})
