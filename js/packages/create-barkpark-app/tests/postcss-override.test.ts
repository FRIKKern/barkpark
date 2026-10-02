// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

/**
 * task-06767d2ff219d51c: a fresh scaffold (either starter, npm) ended its install
 * with "2 vulnerabilities (1 moderate, 1 high)" — postcss <=8.5.22 (XSS via an
 * unescaped </style>; arbitrary file read via sourceMappingURL), pulled in by
 * next@15's own pinned postcss. npm's only offered fix was a SEMVER-MAJOR bump to
 * Next 16. The shared package.json instead overrides postcss to a fixed line for
 * every package manager the scaffolder supports — npm/bun `overrides`, pnpm
 * `pnpm.overrides`, yarn `resolutions` — and pins the direct devDependency to the
 * SAME range (npm refuses an override that disagrees with a direct dependency's
 * spec: EOVERRIDE). Measured after the change: `npm audit --audit-level=high` on
 * a fresh scaffold of each template reports 0 vulnerabilities, and every postcss
 * in the tree (8 instances, next's included) resolves to 8.5.28.
 */
const FIXED = '^8.5.28'

describe('starter package.json overrides the vulnerable postcss', () => {
  const tmpl = readFileSync(
    fileURLToPath(new URL('../templates/_shared/package.json.tmpl', import.meta.url)),
    'utf8',
  )
  const pkg = JSON.parse(tmpl.replace(/\{\{[a-zA-Z]+\}\}/g, 'x')) as {
    devDependencies: Record<string, string>
    overrides?: Record<string, string>
    pnpm?: { overrides?: Record<string, string> }
    resolutions?: Record<string, string>
  }

  it('overrides postcss for npm/bun, pnpm and yarn to the fixed line', () => {
    expect(pkg.overrides?.postcss).toBe(FIXED)
    expect(pkg.pnpm?.overrides?.postcss).toBe(FIXED)
    expect(pkg.resolutions?.postcss).toBe(FIXED)
  })

  it('keeps the direct postcss devDependency on the SAME range (npm EOVERRIDE otherwise)', () => {
    expect(pkg.devDependencies.postcss).toBe(FIXED)
  })

  it('does not reach for a Next major to clear it', () => {
    expect(pkg).toHaveProperty(['dependencies', 'next'], '^15.0.0')
  })
})
