// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Wave-3 render-path-unification parity grid (charter D25 / D28 Option C).
//
// This is the Next.js consumption proof: it drops the canonical, RSC-safe
// `@barkpark/react` `PortableDoc` component into a Next STATIC export (this is a
// Server Component — no `'use client'`) and, for EACH of the frozen pd-golden
// fixtures (produced by W1 slice rpu-w1-golden-gen from the REAL Elixir `:article`
// emitter), renders that single block through the REAL component — NOT `set:html`,
// NOT the `renderPortableDocument` string form. The block array is NOT re-authored:
// the golden mirror is canonical and the fixtures are read verbatim at build time.
//
// Idiom b2 (D25): each golden is wrapped as
//   `<div data-pd-type={type}><PortableDoc value={[block]} /></div>`
// so the vitest suite can extract the INNER `.bp-paper-surface` within each
// `[data-pd-type]` wrapper and compare its outerHTML to the golden via the
// UNCHANGED `dom-shape.ts` comparator (`{ unwrapClass: 'bp-paper-surface' }`).
// No `data-pd-type` is forwarded into the renderer — the wrapper carries the key.
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { PortableDoc } from '@barkpark/react'
import type { Block } from '@barkpark/react'

interface GoldenFixture {
  type: string
  input: Block
  expectedHtml: string
}

// `next build` runs with cwd = the package root (packages/next-parity), so the
// sibling react fixtures resolve deterministically at build time. Reading them in
// a Server Component keeps the whole grid a build-time concern (no client JS).
const FIXTURE_DIR = join(process.cwd(), '..', 'react', 'tests', 'fixtures', 'pd-golden')

function loadFixtures(): GoldenFixture[] {
  return readdirSync(FIXTURE_DIR)
    .filter((f) => f.endsWith('.golden.json'))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(FIXTURE_DIR, f), 'utf8')) as GoldenFixture)
}

export default function ParityGrid() {
  const fixtures = loadFixtures()
  return (
    <main className="bp-parity-fixtures">
      <h1>PortableDoc × Next static-export parity ({fixtures.length} blocks)</h1>
      {fixtures.map((fx) => (
        <div key={fx.type} data-pd-type={fx.type}>
          <PortableDoc value={[fx.input]} />
        </div>
      ))}
    </main>
  )
}
