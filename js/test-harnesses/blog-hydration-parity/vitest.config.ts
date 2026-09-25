import { createRequire } from 'node:module'
import { playwright } from '@vitest/browser-playwright'
import { defineConfig } from 'vitest/config'

// BROWSER MODE IS THE DEFAULT (charter D18/D19). This IS `vitest.config.ts`, so
// the package's plain `test: "vitest run"` script launches a real headless
// Playwright chromium — the ONLY runtime where the media mount points actually
// hydrate: mermaid needs real layout to emit a non-empty SVG, and
// asciinema-player throws on happy-dom's missing 2D-canvas context. It is
// deliberately NOT a `test:browser` side-script, so turbo + CI run it as the
// default `test` task and this proof GATES.
//
// media-parity (W4) proved hydration against fixtures it renders itself. This
// wave proves it against the REAL consuming-app island — create-barkpark-app's
// `PortableDocSurface` — imported READ-ONLY from the template tree. That import
// costs four load-bearing knobs a bare browser config does not need (each one
// was a red in the epic probe); they are why this file diverges from
// media-parity's:

const require = createRequire(import.meta.url)

export default defineConfig({
  // KNOB 1 — automatic JSX. The template island is written for Next's compiler
  // and imports NO React (no `import React`). esbuild must inject the automatic
  // runtime from `react/jsx-runtime`, or every JSX element throws "React is not
  // defined".
  esbuild: {
    jsx: 'automatic',
    jsxImportSource: 'react',
  },
  resolve: {
    // KNOB 2 — pin every React specifier to THIS package's own react. The
    // blog-starter template is NOT a workspace package, so the island's bare
    // `react` / `react-dom/client` peer specifiers do not resolve from the
    // template tree. Alias them (and both jsx runtimes) to the single react
    // this package installs, so the island, @testing-library/react, and
    // @barkpark/react all share ONE React instance (mismatched copies break
    // hooks with "invalid hook call").
    //
    // EXACT-MATCH regexes (`^…$`), not bare strings: a string alias for
    // `react-dom` is a PREFIX rule, so it would rewrite `react-dom/test-utils`
    // (imported by @testing-library/react) to `<index.js>/test-utils` and blow
    // up. Anchored finds pin only the exact specifiers; sibling subpaths
    // resolve normally (to the same deduped copy).
    alias: [
      { find: /^react$/, replacement: require.resolve('react') },
      { find: /^react\/jsx-runtime$/, replacement: require.resolve('react/jsx-runtime') },
      { find: /^react\/jsx-dev-runtime$/, replacement: require.resolve('react/jsx-dev-runtime') },
      { find: /^react-dom$/, replacement: require.resolve('react-dom') },
      { find: /^react-dom\/client$/, replacement: require.resolve('react-dom/client') },
    ],
  },
  test: {
    name: 'blog-hydration-parity',
    // The island proof is a .tsx (it mounts a real React component), so the
    // glob extends media-parity's `.browser.test.ts` to `.tsx`.
    include: ['tests/**/*.browser.test.{ts,tsx}'],
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
