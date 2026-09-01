// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The READ side of the cache-tag contract, guarded the way the WRITE side
// (src/revalidate/index.ts) already is.
//
// `opts.tags` / `opts.syncTags` are typed `readonly string[]`, but the type
// closes nothing: excess-property checks fire only on fresh literals, and this
// package ships CJS/ESM consumable from plain JS where no type exists at all.
// A bare STRING is iterable, so `tags: 'my-tag'` spread to
// ['m','y','-','t','a','g'] — and the per-element `typeof t === 'string'`
// filter is exactly what made it SILENT, since every character passes it. The
// fetch was then cached under six junk single-character tags and never under
// the real one, so `revalidateTag('my-tag')` never matched: permanently stale
// page, no error anywhere.
//
// These assert the SUBJECT IS PRESENT ('my-tag' in the array), not merely that
// the junk is absent — a guard that dropped the caller's tags entirely would
// also produce a 'm'-free array while still breaking revalidation.

import { describe, it, expect, beforeEach, vi } from 'vitest'

const { draftModeMock } = vi.hoisted(() => ({
  draftModeMock: vi.fn(async () => ({ isEnabled: false })),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

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

function okResponse(): Response {
  return new Response(JSON.stringify({ result: { documents: [] } }), { status: 200 })
}

/** Run one published-branch fetch and return the `next.tags` it built. */
async function tagsFor(opts: Record<string, unknown>): Promise<string[]> {
  const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(okResponse())
  await barkparkFetch(makeCfg(), { type: 'post', ...opts } as never)
  const init = fetchSpy.mock.calls[0]![1] as {
    next?: { tags?: string[] }
  }
  return init.next?.tags ?? []
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

describe('barkparkFetch — a bare-string `tags` must not be walked character by character', () => {
  it('keeps a bare-string `tags` whole', async () => {
    const tags = await tagsFor({ tags: 'my-tag' })
    expect(tags).toContain('my-tag')
    expect(tags).not.toContain('m')
    expect(tags).not.toContain('y')
    expect(tags).not.toContain('-')
  })

  it('keeps a bare-string `syncTags` whole', async () => {
    const tags = await tagsFor({ syncTags: 'bp:ds:production:doc:p1' })
    expect(tags).toContain('bp:ds:production:doc:p1')
    expect(tags).not.toContain('b')
    expect(tags).not.toContain(':')
  })

  it('still fans out a normal array of tags, canonical tags included', async () => {
    const tags = await tagsFor({ tags: ['a-tag', 'b-tag'], syncTags: ['s-tag'] })
    expect(tags).toContain('bp:ds:production:_all')
    expect(tags).toContain('bp:ds:production:type:post')
    expect(tags).toContain('a-tag')
    expect(tags).toContain('b-tag')
    expect(tags).toContain('s-tag')
  })

  it('ignores a non-array, non-string `tags` instead of throwing (write-side parity)', async () => {
    const tags = await tagsFor({ tags: 42 })
    expect(tags).toEqual(['bp:ds:production:_all', 'bp:ds:production:type:post'])
  })

  it('drops an empty-string `tags` rather than emitting an empty tag', async () => {
    const tags = await tagsFor({ tags: '' })
    expect(tags).toEqual(['bp:ds:production:_all', 'bp:ds:production:type:post'])
  })
})
