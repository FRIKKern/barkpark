// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Drift guard for the shipped `paper-surface.css` asset (charter D12).
//
// `@barkpark/react` ships `dist/paper-surface.css` as a byte-for-byte COPY of
// `api/assets/paper-surface/paper-surface.css` — the source of Phoenix's
// `Render.Stylesheet.css/0`. That source lives OUTSIDE `js/`'s turbo+pnpm
// workspace, so turbo's build-cache hash never observes edits to it. This test
// is the real safety net: it asserts the copied asset exists after build and is
// byte-identical to the api source, so an api-side CSS edit that the tsup copy
// missed (or a stale turbo cache) fails CI instead of shipping drift.

import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { describe, it, expect } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
// tests/ -> package root -> dist/paper-surface.css
const SHIPPED = join(here, '..', 'dist', 'paper-surface.css')
// tests/ -> react -> packages -> js -> repo root -> api/assets/...
const SOURCE = join(here, '..', '..', '..', '..', 'api', 'assets', 'paper-surface', 'paper-surface.css')

describe('paper-surface.css asset', () => {
  it('is emitted to dist after build (run `pnpm build` first)', () => {
    expect(
      existsSync(SHIPPED),
      `Expected ${SHIPPED} to exist. Run the build before the test — the tsup onSuccess hook copies it.`,
    ).toBe(true)
  })

  it('is byte-identical to the api source of truth (drift guard, D12)', async () => {
    const [shipped, source] = await Promise.all([readFile(SHIPPED), readFile(SOURCE)])
    expect(
      shipped.equals(source),
      'dist/paper-surface.css drifted from api/assets/paper-surface/paper-surface.css. ' +
        'The stylesheet has ONE source of truth; re-run the build so the tsup copy re-syncs.',
    ).toBe(true)
  })
})
