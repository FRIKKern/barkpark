import { afterEach, describe, expect, it, vi } from 'vitest'
import { createClient } from '../src/client'
import { searchDocuments } from '../src/search'
import { uploadAsset } from '../src/media'
import { BarkparkValidationError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: 'https://example.test',
  dataset: 'production',
  apiVersion: '2026-04-17',
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('search — type/types mutual exclusion', () => {
  it('throws when both type and a non-empty types are given (empty-by-construction filter)', async () => {
    await expect(
      searchDocuments(baseConfig, 'cms', { type: 'post', types: ['author'] }),
    ).rejects.toThrow(BarkparkValidationError)
  })

  it('allows type alone', async () => {
    // A fetch spy proves the guard passed (we don't care about the response shape).
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ documents: [], count: 0 }), { status: 200 }),
    )
    await searchDocuments(baseConfig, 'cms', { type: 'post' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('allows an empty types array alongside type (no restriction, no conflict)', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ documents: [], count: 0 }), { status: 200 }),
    )
    await searchDocuments(baseConfig, 'cms', { type: 'post', types: [] })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})

describe('getDocuments — type/ids guards', () => {
  it('throws on a bare-string ids arg BEFORE any network call', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    const bp = createClient(baseConfig)
    // 'p1' has length 2, so it slips past the old `ids.length === 0` check and
    // would fire a request, then die at `ids.map is not a function`.
    await expect(
      // @ts-expect-error — deliberately passing a string where string[] is required
      bp.getDocuments('post', 'p1'),
    ).rejects.toThrow(BarkparkValidationError)
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('throws on a non-array ids arg', async () => {
    const bp = createClient(baseConfig)
    await expect(
      // @ts-expect-error — deliberately passing a non-array
      bp.getDocuments('post', 42),
    ).rejects.toThrow(BarkparkValidationError)
  })

  it('throws on an empty/non-string type', async () => {
    const bp = createClient(baseConfig)
    await expect(bp.getDocuments('', ['p1'])).rejects.toThrow(BarkparkValidationError)
    await expect(
      // @ts-expect-error — deliberately passing a non-string type
      bp.getDocuments(null, ['p1']),
    ).rejects.toThrow(BarkparkValidationError)
  })

  it('throws when any id element is a non-empty-string', async () => {
    const bp = createClient(baseConfig)
    await expect(
      // @ts-expect-error — deliberately passing a non-string element
      bp.getDocuments('post', ['p1', 2]),
    ).rejects.toThrow(BarkparkValidationError)
    await expect(bp.getDocuments('post', ['p1', ''])).rejects.toThrow(BarkparkValidationError)
  })

  it('still returns [] for an empty ids array (after the array guard)', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    const bp = createClient(baseConfig)
    await expect(bp.getDocuments('post', [])).resolves.toEqual([])
    expect(fetchSpy).not.toHaveBeenCalled()
  })
})

describe('uploadAsset — Blob duck-type guard', () => {
  it('throws on null', async () => {
    await expect(
      // @ts-expect-error — deliberately passing null
      uploadAsset(baseConfig, null),
    ).rejects.toThrow(BarkparkValidationError)
  })

  it('throws on a path string (the classic Node mistake)', async () => {
    await expect(
      // @ts-expect-error — deliberately passing a path string, not file contents
      uploadAsset(baseConfig, '/tmp/photo.png'),
    ).rejects.toThrow(BarkparkValidationError)
  })

  it('accepts a real Blob (arrayBuffer duck-type passes)', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ _id: 'a1', _type: 'sanity.imageAsset' }), { status: 200 }),
    )
    await uploadAsset(baseConfig, new Blob(['hi'], { type: 'text/plain' }), { filename: 'x.txt' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})
