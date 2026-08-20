// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// RSC-safety guard for the shipped `dist/server.mjs` chunk graph (charter D24,
// W3 prerequisite).
//
// `@barkpark/react`'s `server` entry is the package's `react-server` export
// condition — what Next 15's App Router resolves when a Server Component does
// `import { PortableDoc } from '@barkpark/react'`. `PortableDoc` /
// `renderPortableDocument` are context-free and hook-free BY DESIGN (D2/D3), so
// they must ship from a chunk the RSC runtime can evaluate on the server.
//
// The regression this locks: with tsup `splitting: true`, `Image.tsx`
// (`BarkparkImage`, `'use client'`, calls `useEffect`) is imported by BOTH the
// client (`index`) and server (`server`) entries. Without a dedicated `image`
// entry to pin it, esbuild co-bundles it into the ONE shared renderer chunk, so
// that chunk's head becomes `import { …, useEffect } from 'react'`. `server.mjs`
// then re-exports the renderers from that same hook-importing chunk, and any
// Next Server Component import drags `useEffect` into the server graph →
// `next build` fails under the `react-server` condition (`useEffect` is absent
// there). See `tsup.config.ts` for the fix (isolate `Image.tsx` as its own
// entry + banner its chunk `"use client"`).
//
// This test resolves — from the built `dist/server.mjs` — the chunk(s) it
// re-exports the renderers from, follows their transitive chunk imports, and
// asserts NONE of them import a React hook (or `createContext`, the other
// `react-server`-absent API). Run the build before the test.

import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { describe, it, expect } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
const DIST = join(here, '..', 'dist')

// The RSC-safe renderers `server.mjs` promises to expose from a server-evaluable
// (hook-free) chunk. If the split regresses, these land in a hook chunk.
const RSC_RENDERERS = ['PortableDoc', 'renderPortableDocument'] as const

// `react` / `react-dom` named imports that DO NOT exist under the `react-server`
// export condition — importing any of them at module scope breaks an RSC build.
// Hooks match `use[A-Z]…`; `createContext` is the non-hook member (D3).
function rscForbiddenReactImports(source: string): string[] {
  const found = new Set<string>()
  // Every `import { a, b as c } from 'react' | 'react-dom' | 'react/…'`.
  const importRe = /import\s*\{([^}]*)\}\s*from\s*['"]react(?:-dom)?(?:\/[^'"]*)?['"]/g
  for (const m of source.matchAll(importRe)) {
    for (const raw of (m[1] ?? '').split(',')) {
      // `original as local` → the original binding is what's pulled from react.
      const name = (raw.trim().split(/\s+as\s+/)[0] ?? '').trim()
      if (!name) continue
      if (/^use[A-Z]/.test(name) || name === 'createContext') found.add(name)
    }
  }
  return [...found]
}

// The `./chunk-XXX.(mjs|cjs)` files a module statically imports or re-exports from.
function chunkRefs(source: string): string[] {
  const refs = new Set<string>()
  for (const m of source.matchAll(/from\s*['"]\.\/(chunk-[A-Za-z0-9]+\.(?:mjs|cjs))['"]/g)) {
    if (m[1]) refs.add(m[1])
  }
  return [...refs]
}

// Which chunk file a given export name is re-exported from in `entrySource`
// (`export { …, name, … } from './chunk-XXX.mjs'`). Null if not chunk-sourced.
function chunkForExport(entrySource: string, name: string): string | null {
  const re = /export\s*\{([^}]*)\}\s*from\s*['"]\.\/(chunk-[A-Za-z0-9]+\.(?:mjs|cjs))['"]/g
  for (const m of entrySource.matchAll(re)) {
    const names = (m[1] ?? '').split(',').map((s) => (s.trim().split(/\s+as\s+/).pop() ?? '').trim())
    if (names.includes(name)) return m[2] ?? null
  }
  return null
}

// The transitive closure of chunks reachable from `roots`, following chunk refs.
async function chunkClosure(roots: string[]): Promise<Map<string, string>> {
  const seen = new Map<string, string>()
  const queue = [...roots]
  while (queue.length) {
    const chunk = queue.pop()!
    if (seen.has(chunk)) continue
    const body = await readFile(join(DIST, chunk), 'utf8')
    seen.set(chunk, body)
    for (const ref of chunkRefs(body)) if (!seen.has(ref)) queue.push(ref)
  }
  return seen
}

describe('RSC chunk graph is hook-free (dist/server.mjs)', () => {
  it('server.mjs re-exports the renderers from chunk(s), not inline (build ran)', async () => {
    const server = await readFile(join(DIST, 'server.mjs'), 'utf8')
    for (const name of RSC_RENDERERS) {
      const chunk = chunkForExport(server, name)
      expect(
        chunk,
        `dist/server.mjs does not re-export ${name} from a ./chunk-*.mjs — did the build run, or did the entry shape change?`,
      ).toBeTruthy()
    }
  })

  it('no chunk the renderers are re-exported from imports a react-server-absent API', async () => {
    const server = await readFile(join(DIST, 'server.mjs'), 'utf8')

    const rootChunks = new Set<string>()
    for (const name of RSC_RENDERERS) {
      const chunk = chunkForExport(server, name)
      if (chunk) rootChunks.add(chunk)
    }
    expect(rootChunks.size).toBeGreaterThan(0)

    const closure = await chunkClosure([...rootChunks])
    const offenders: Record<string, string[]> = {}
    for (const [chunk, body] of closure) {
      const bad = rscForbiddenReactImports(body)
      if (bad.length) offenders[chunk] = bad
    }

    expect(
      offenders,
      'The renderer chunk graph that dist/server.mjs re-exports PortableDoc/renderPortableDocument from ' +
        'imports a React hook (or createContext), which does NOT exist under the react-server condition. ' +
        'A Next Server Component importing @barkpark/react would fail `next build`. The client surface ' +
        '(BarkparkImage) must stay isolated in its own "use client" chunk — see tsup.config.ts.',
    ).toEqual({})
  })

  it('the BarkparkImage chunk (the hook-bearing client surface) IS "use client" bannered', async () => {
    // The complement of the guard above: BarkparkImage legitimately uses a hook,
    // and server.mjs re-exports it (locked by exports-server.test.ts) — so its
    // chunk MUST carry the client-boundary banner, or the hook it imports would
    // leak into the RSC graph despite living in a separate chunk.
    const server = await readFile(join(DIST, 'server.mjs'), 'utf8')
    const imageChunk = chunkForExport(server, 'BarkparkImage')
    expect(
      imageChunk,
      'dist/server.mjs must re-export BarkparkImage from a ./chunk-*.mjs (exports-server.test.ts locks its presence).',
    ).toBeTruthy()

    const body = await readFile(join(DIST, imageChunk!), 'utf8')
    expect(
      rscForbiddenReactImports(body).length,
      'Expected the BarkparkImage chunk to actually use a hook — otherwise this guard proves nothing about isolation.',
    ).toBeGreaterThan(0)
    expect(
      body.startsWith('"use client"') || body.startsWith("'use client'"),
      `The BarkparkImage chunk ${imageChunk} imports a React hook but is NOT "use client" bannered — ` +
        'a Server Component that imports BarkparkImage would drag the hook into the RSC graph. ' +
        'Extend tsup.config.ts onSuccess to banner it.',
    ).toBe(true)
  })
})
