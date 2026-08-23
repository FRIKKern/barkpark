// Parity with core (js/packages/core/src/doc.ts + filter-builder.ts
// normalizeFieldList): the /doc read guards expand/fields so a comma inside a
// field name can't silently split into extra projected/expanded fields (an
// over-broad read), a stray '' can't ship a phantom `fields=title,,slug`, and
// an empty list throws instead of silently no-oping. barkparkFetch's id-path
// used to `join(',')` unguarded — the exact corruption core fails closed on.
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

function okFetchSpy() {
  return vi
    .spyOn(globalThis, 'fetch')
    .mockResolvedValue(new Response(JSON.stringify({ result: { _id: 'p1' } }), { status: 200 }))
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

describe('barkparkFetch — expand/fields fail closed like core getDoc', () => {
  it('rejects a comma inside an expand entry instead of silently splitting it', async () => {
    okFetchSpy()
    await expect(
      barkparkFetch(makeCfg(), { type: 'post', id: 'p1', expand: ['author,tags'] }),
    ).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('rejects a comma inside a fields entry', async () => {
    okFetchSpy()
    await expect(
      barkparkFetch(makeCfg(), { type: 'post', id: 'p1', fields: ['title,slug'] }),
    ).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('throws on an empty expand list instead of silently omitting the param', async () => {
    okFetchSpy()
    await expect(
      barkparkFetch(makeCfg(), { type: 'post', id: 'p1', expand: [] }),
    ).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('trims entries and drops empties so a stray "" cannot ship a phantom field', async () => {
    const spy = okFetchSpy()
    await barkparkFetch(makeCfg(), {
      type: 'post',
      id: 'p1',
      fields: [' title ', '', 'slug'],
    })
    const url = String(spy.mock.calls[0]?.[0])
    expect(url).toContain('fields=title%2Cslug')
  })

  it('a clean single-string expand still passes through', async () => {
    const spy = okFetchSpy()
    await barkparkFetch(makeCfg(), { type: 'post', id: 'p1', expand: 'author' })
    const url = String(spy.mock.calls[0]?.[0])
    expect(url).toContain('expand=author')
  })
})
