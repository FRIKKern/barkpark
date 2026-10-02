// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// THE NON-VACUOUS GUARD (charter D18, distrust-vacuous-green doctrine).
//
// @barkpark/astro-parity's zero-JS proof asserts the built site ships NO JS and
// emits NO `<astro-island>`. A green there is only meaningful if those same two
// checks can turn RED — otherwise they might be structurally incapable of failing
// (e.g. globbing the wrong dir, or a substring that can never appear).
//
// This package builds a DELIBERATELY hydrated Astro site (a `client:load` React
// island via @astrojs/react) and runs the SAME two checks with INVERTED assertions:
// it PROVES the site DOES ship `_astro/*.js` and DOES emit `<astro-island>`. Green
// here == "the parity checks discriminate." It is a SEPARATE package so @astrojs/react
// never enters astro-parity's dependency graph (charter D22).

import { describe, it, expect } from 'vitest'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const PKG_ROOT = join(HERE, '..')
const DIST = join(PKG_ROOT, 'dist')
const BUILT_HTML = join(DIST, 'index.html')

/** Same predicate astro-parity uses: every `.js`/`.mjs`/`.cjs` under `dir` (recursive). */
function shippedJs(dir: string): string[] {
  if (!existsSync(dir)) return []
  return readdirSync(dir, { recursive: true, encoding: 'utf8' }).filter((p) =>
    /\.(m|c)?js$/.test(p),
  )
}

describe('decoy — a client:load island MAKES the parity checks turn red (inverted, so this passes)', () => {
  it('the decoy build exists', () => {
    expect(
      existsSync(BUILT_HTML),
      'run `astro build` (pnpm --filter @barkpark/astro-decoy build) first',
    ).toBe(true)
  })

  it('DOES ship JS in the built site — inverts astro-parity’s "dist/**/*.js is empty"', () => {
    const js = shippedJs(DIST)
    // The parity package asserts this is EMPTY; hydration makes it non-empty.
    expect(js.length, 'expected a hydrated build to ship JS, but it shipped none').toBeGreaterThan(
      0,
    )
  })

  it('DOES ship JS under dist/_astro — inverts astro-parity’s "_astro is JS-free"', () => {
    const astroJs = shippedJs(join(DIST, '_astro'))
    expect(
      astroJs.length,
      'expected the island bundle under dist/_astro, found none',
    ).toBeGreaterThan(0)
  })

  it('DOES emit <astro-island> — inverts astro-parity’s "no astro-island marker"', () => {
    const html = readFileSync(BUILT_HTML, 'utf8')
    expect(html, 'expected an <astro-island> hydration marker, found none').toContain(
      '<astro-island',
    )
  })
})
