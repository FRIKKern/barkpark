// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// CAPABILITY: `barkparkFetch({ type, id })` fetches the document the caller
// named, or refuses — it never silently fetches a DIFFERENT endpoint.
//
// `encodeURIComponent` escapes `/` and `\` but NOT `.`, so an id (or type) of
// `'..'` reached `fetch` intact and the WHATWG URL parser resolved it before the
// request left, retargeting the call. Bounded, and the payoff was checked:
// api router declares `get("/doc/:dataset/:type/:doc_id", …)` and nothing at
// `/v1/data/doc/:dataset`, so the retarget 404s — this is NOT an over-broad
// read. The residual harm is a confusing `BarkparkNotFoundError` naming a URL
// the caller never asked for, and a Next data-cache entry tagged
// `<prefix>:doc:..` that no `revalidateTag` will ever match.
//
// @barkpark/core closed the same class in `util/guards.ts` (`assertSegment`).
// It is not on core's public export surface, so this package mirrors the rule —
// the same precedent `normalizeFieldList` in server/core.ts already set.

import { describe, it, expect, beforeEach, vi } from 'vitest'

const { draftModeMock } = vi.hoisted(() => ({
  draftModeMock: vi.fn(async () => ({ isEnabled: false })),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

import { BarkparkValidationError } from '@barkpark/core'
import { barkparkFetch } from '../src/server/index'
import type { BarkparkServerConfig } from '../src/server/index'

function makeCfg(): BarkparkServerConfig {
  return {
    client: {
      config: {
        projectUrl: 'http://localhost:4000',
        dataset: 'production',
        apiVersion: '2026-01-01',
      },
    } as unknown as BarkparkServerConfig['client'],
    serverToken: 's-tok-123',
  }
}

/** Records every URL handed to fetch, and answers 200 so nothing else throws. */
function recordUrls(): string[] {
  const seen: string[] = []
  vi.spyOn(globalThis, 'fetch').mockImplementation((url) => {
    seen.push(String(url))
    return Promise.resolve(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
  })
  return seen
}

/** What the WHATWG URL parser — and therefore `fetch` — actually resolves to. */
function resolvedPaths(seen: readonly string[]): string[] {
  return seen.map((u) => new URL(u).pathname)
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

describe('barkparkFetch — a path segment may not be a relative-path operator', () => {
  it('CONTROL: a legitimate id emits exactly the single-document path, unresolved and unretargeted', async () => {
    const seen = recordUrls()
    await barkparkFetch(makeCfg(), { type: 'post', id: 'p1' })
    expect(seen).toEqual(['http://localhost:4000/v1/data/doc/production/post/p1'])
    expect(resolvedPaths(seen)).toEqual(['/v1/data/doc/production/post/p1'])
  })

  it("CONTROL: '/' in an id is escaped, so traversal was already capped at one segment", async () => {
    const seen = recordUrls()
    await expect(barkparkFetch(makeCfg(), { type: 'post', id: 'a/b' })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    // Rejected outright (core's rule: no id in this API legitimately holds a
    // separator), so nothing is emitted at all.
    expect(seen).toEqual([])
  })

  it("an id of '..' emits NO url — before the guard it emitted one resolving to /v1/data/doc/production/", async () => {
    const seen = recordUrls()
    await expect(barkparkFetch(makeCfg(), { type: 'post', id: '..' })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    expect(resolvedPaths(seen)).toEqual([])
  })

  it("an id of '.' emits NO url", async () => {
    const seen = recordUrls()
    await expect(barkparkFetch(makeCfg(), { type: 'post', id: '.' })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    expect(resolvedPaths(seen)).toEqual([])
  })

  it("a type of '..' on the single-doc path emits NO url — before the guard it resolved to /v1/data/doc/x", async () => {
    const seen = recordUrls()
    await expect(barkparkFetch(makeCfg(), { type: '..', id: 'x' })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    expect(resolvedPaths(seen)).toEqual([])
  })

  it("a type of '..' on the LIST path emits NO url", async () => {
    const seen = recordUrls()
    await expect(barkparkFetch(makeCfg(), { type: '..' })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    expect(resolvedPaths(seen)).toEqual([])
  })

  it('a whitespace-only id emits NO url (it collapses the path the same way)', async () => {
    const seen = recordUrls()
    await expect(barkparkFetch(makeCfg(), { type: 'post', id: '   ' })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    expect(resolvedPaths(seen)).toEqual([])
  })

  it('CONTROL: the list path for a legitimate type is unchanged', async () => {
    const seen = recordUrls()
    await barkparkFetch(makeCfg(), { type: 'post' })
    expect(seen).toEqual(['http://localhost:4000/v1/data/query/production/post'])
  })
})
