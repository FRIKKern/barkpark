import { playwright } from '@vitest/browser-playwright'
import { defineConfig } from 'vitest/config'

// The `browser` project exists for ONE reason the `client` (jsdom-under-node)
// project structurally cannot serve: in jsdom `process` ALWAYS exists, because
// the test runs inside node. `detectEdgeRuntime()`'s browser behaviour — the
// thing every consumer of `@barkpark/nextjs/client` actually hits — was
// therefore never executed by a test, and the fault it hid (a plain browser
// classified as an edge runtime, crashing the React tree at render) shipped
// behind a comment claiming "covered structurally".
//
// A real headless chromium is the ONLY runtime where `typeof process` is
// genuinely `'undefined'` and `ReadableStream` is genuinely present at once.
//
// Wired into the package's default `test` script (NOT a `test:browser`
// side-script) so turbo + CI actually run it — the trap `@barkpark/core`'s
// `test:browser` fell into and `@barkpark/media-parity` documents.
export default defineConfig({
  test: {
    name: 'browser',
    include: ['tests/**/*.browser.test.ts', 'tests/**/*.browser.test.tsx'],
    // NOTE: no `setupFiles` — the shared `test-utils/vitest.setup.ts` boots
    // `msw/node`, which cannot load inside a browser.
    browser: {
      enabled: true,
      // vitest 4: `browser.provider` is a factory from
      // `@vitest/browser-playwright`; `browser.instances` replaces `browser.name`.
      provider: playwright(),
      instances: [{ browser: 'chromium' }],
      headless: true,
      // These tests assert on runtime detection and subscription wiring, not on
      // pixels — a failure screenshot of an empty page adds nothing, and the
      // default would drop untracked PNGs into tests/__screenshots__/ on every
      // red run.
      screenshotFailures: false,
    },
  },
})
