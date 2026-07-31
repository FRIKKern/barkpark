// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `activeMermaidTheme` — the theme-derivation seam `hydratePortableDoc` feeds
// into `mermaid.initialize` so dark-mode diagrams are legible (jarl-dogfood
// wave). Resolution contract: an explicit `data-theme` stamp on `<html>` wins
// (`dark` → dark, any other stamp → light), else `prefers-color-scheme`
// decides. Table-driven over a fake Document so it runs in the node env — the
// end-to-end SVG render is covered by the media-parity browser suite.

import { describe, it, expect } from 'vitest'
import { activeMermaidTheme } from '../src/client'

function fakeDoc(opts: {
  dataTheme?: string | null
  prefersDark?: boolean
  noMatchMedia?: boolean
}): Document {
  return {
    documentElement: {
      getAttribute: (name: string) => (name === 'data-theme' ? (opts.dataTheme ?? null) : null),
    },
    defaultView: opts.noMatchMedia
      ? {}
      : {
          matchMedia: (query: string) => ({
            matches: query.includes('dark') ? (opts.prefersDark ?? false) : false,
          }),
        },
  } as unknown as Document
}

describe('activeMermaidTheme', () => {
  const cases: Array<{
    name: string
    doc: Document
    expected: 'dark' | 'default'
  }> = [
    {
      name: 'data-theme="dark" stamp wins → dark (even when the OS prefers light)',
      doc: fakeDoc({ dataTheme: 'dark', prefersDark: false }),
      expected: 'dark',
    },
    {
      name: 'data-theme="light" stamp wins → default (even when the OS prefers dark)',
      doc: fakeDoc({ dataTheme: 'light', prefersDark: true }),
      expected: 'default',
    },
    {
      name: 'any other explicit stamp is a light surface → default',
      doc: fakeDoc({ dataTheme: 'sepia', prefersDark: true }),
      expected: 'default',
    },
    {
      name: 'no stamp + OS prefers dark → dark',
      doc: fakeDoc({ dataTheme: null, prefersDark: true }),
      expected: 'dark',
    },
    {
      name: 'no stamp + OS prefers light → default',
      doc: fakeDoc({ dataTheme: null, prefersDark: false }),
      expected: 'default',
    },
    {
      name: 'an empty-string stamp is no stamp — falls through to prefers-color-scheme',
      doc: fakeDoc({ dataTheme: '', prefersDark: true }),
      expected: 'dark',
    },
    {
      name: 'no matchMedia available (SSR-ish window) → default, never a throw',
      doc: fakeDoc({ dataTheme: null, noMatchMedia: true }),
      expected: 'default',
    },
  ]

  for (const c of cases) {
    it(c.name, () => {
      expect(activeMermaidTheme(c.doc)).toBe(c.expected)
    })
  }
})
