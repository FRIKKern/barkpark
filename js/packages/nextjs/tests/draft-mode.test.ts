import { describe, it, expect, beforeEach, vi } from 'vitest'
import { createHmac } from 'node:crypto'

const { enableMock, disableMock, draftModeMock } = vi.hoisted(() => ({
  enableMock: vi.fn(),
  disableMock: vi.fn(),
  draftModeMock: vi.fn(),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

import { createDraftModeRoutes, signDraftModeToken } from '../src/draft-mode/index'

function makeGet(qs: Record<string, string>): Request {
  const url = new URL('http://localhost/api/draft')
  for (const [k, v] of Object.entries(qs)) url.searchParams.set(k, v)
  return new Request(url.toString(), { method: 'GET' })
}

beforeEach(() => {
  enableMock.mockReset()
  disableMock.mockReset()
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ enable: enableMock, disable: disableMock })
})

describe('signDraftModeToken', () => {
  it('emits a hex-HMAC-SHA256 signature over path + "\\n" + expiry', () => {
    const secret = 'shh'
    const now = 1_700_000_000_000
    const out = signDraftModeToken({ path: '/posts/x', secret, now })
    const expected = createHmac('sha256', secret).update(`/posts/x\n${out.expiry}`).digest('hex')
    expect(out.sign).toBe(expected)
    expect(out.sign).toMatch(/^[0-9a-f]{64}$/)
    expect(out.expiry).toBe(now + 10 * 60 * 1000)
  })

  it('rejects empty secret and empty path', () => {
    expect(() => signDraftModeToken({ path: '', secret: 'x' })).toThrow()
    expect(() => signDraftModeToken({ path: '/x', secret: '' })).toThrow()
  })
})

describe('createDraftModeRoutes — GET (happy path)', () => {
  it('verifies signed URL, enables draft mode, and 307-redirects to path', async () => {
    const secret = 'shh'
    const { GET } = createDraftModeRoutes({ previewSecret: secret })
    const { path, expiry, sign } = signDraftModeToken({ path: '/posts/hello', secret })

    const res = await GET(makeGet({ path, expiry: String(expiry), sign }))

    expect(res.status).toBe(307)
    expect(res.headers.get('Location')).toBe('/posts/hello')
    expect(draftModeMock).toHaveBeenCalledOnce()
    expect(enableMock).toHaveBeenCalledOnce()
    expect(disableMock).not.toHaveBeenCalled()
  })

  it('applies resolvePath to rewrite the redirect target', async () => {
    const secret = 'shh'
    const { GET } = createDraftModeRoutes({
      previewSecret: secret,
      resolvePath: (p) => `/preview${p}`,
    })
    const { path, expiry, sign } = signDraftModeToken({ path: '/posts/x', secret })

    const res = await GET(makeGet({ path, expiry: String(expiry), sign }))

    expect(res.headers.get('Location')).toBe('/preview/posts/x')
  })
})

describe('createDraftModeRoutes — GET (rejections)', () => {
  it('returns 401 when required query params are missing', async () => {
    const { GET } = createDraftModeRoutes({ previewSecret: 'shh' })
    const res = await GET(new Request('http://localhost/api/draft'))
    expect(res.status).toBe(401)
    expect(await res.text()).toContain('missing')
    expect(enableMock).not.toHaveBeenCalled()
  })

  it('rejects expired tokens with 401', async () => {
    const secret = 'shh'
    const { GET } = createDraftModeRoutes({ previewSecret: secret })
    const expiry = Date.now() - 1_000
    const sign = createHmac('sha256', secret).update(`/p\n${expiry}`).digest('hex')

    const res = await GET(makeGet({ path: '/p', expiry: String(expiry), sign }))

    expect(res.status).toBe(401)
    expect(await res.text()).toContain('expired')
    expect(enableMock).not.toHaveBeenCalled()
  })

  it('rejects tampered signatures with 401 (wrong path)', async () => {
    const secret = 'shh'
    const { GET } = createDraftModeRoutes({ previewSecret: secret })
    const { expiry, sign } = signDraftModeToken({ path: '/real', secret })

    const res = await GET(makeGet({ path: '/evil', expiry: String(expiry), sign }))

    expect(res.status).toBe(401)
    expect(await res.text()).toContain('mismatch')
  })

  it('rejects signatures produced under a different secret', async () => {
    const { GET } = createDraftModeRoutes({ previewSecret: 'right-key' })
    const { path, expiry, sign } = signDraftModeToken({ path: '/p', secret: 'wrong-key' })

    const res = await GET(makeGet({ path, expiry: String(expiry), sign }))

    expect(res.status).toBe(401)
  })
})

describe('createDraftModeRoutes — GET (one-shot reissue)', () => {
  it('on verify fail, calls reissuePreviewToken once and succeeds under returned secret', async () => {
    const current = 'current-key'
    const previous = 'previous-key'
    const reissue = vi.fn(async () => previous)
    const { GET } = createDraftModeRoutes({ previewSecret: current, reissuePreviewToken: reissue })
    const { path, expiry, sign } = signDraftModeToken({ path: '/p', secret: previous })

    const res = await GET(makeGet({ path, expiry: String(expiry), sign }))

    expect(reissue).toHaveBeenCalledOnce()
    expect(res.status).toBe(307)
    expect(res.headers.get('Location')).toBe('/p')
    expect(enableMock).toHaveBeenCalledOnce()
  })

  it('second verify failure bubbles as 401 and reissue is called exactly once', async () => {
    const reissue = vi.fn(async () => 'still-wrong-key')
    const { GET } = createDraftModeRoutes({
      previewSecret: 'current-key',
      reissuePreviewToken: reissue,
    })
    const { path, expiry, sign } = signDraftModeToken({ path: '/p', secret: 'unrelated-key' })

    const res = await GET(makeGet({ path, expiry: String(expiry), sign }))

    expect(reissue).toHaveBeenCalledOnce()
    expect(res.status).toBe(401)
    expect(enableMock).not.toHaveBeenCalled()
  })

  it('does not retry an expired token — expiry is clock-checked before/after reissue', async () => {
    const reissue = vi.fn(async () => 'any-secret')
    const { GET } = createDraftModeRoutes({
      previewSecret: 'current-key',
      reissuePreviewToken: reissue,
    })
    const expiry = Date.now() - 10_000
    const sign = createHmac('sha256', 'any-secret').update(`/p\n${expiry}`).digest('hex')

    const res = await GET(makeGet({ path: '/p', expiry: String(expiry), sign }))

    expect(res.status).toBe(401)
    expect(enableMock).not.toHaveBeenCalled()
  })
})

describe('createDraftModeRoutes — DELETE', () => {
  it('calls draftMode().disable() and returns 200', async () => {
    const { DELETE } = createDraftModeRoutes({ previewSecret: 'shh' })

    const res = await DELETE(new Request('http://localhost/api/draft', { method: 'DELETE' }))

    expect(res.status).toBe(200)
    expect(draftModeMock).toHaveBeenCalledOnce()
    expect(disableMock).toHaveBeenCalledOnce()
    expect(enableMock).not.toHaveBeenCalled()
  })
})

describe('createDraftModeRoutes — config validation', () => {
  it('throws when previewSecret is missing or empty', () => {
    // @ts-expect-error — testing runtime guard
    expect(() => createDraftModeRoutes({})).toThrow(/previewSecret/)
    expect(() => createDraftModeRoutes({ previewSecret: '' })).toThrow(/previewSecret/)
  })

  it('throws when resolvePath is provided but not a function', () => {
    expect(() =>
      // @ts-expect-error — testing runtime guard
      createDraftModeRoutes({ previewSecret: 's', resolvePath: 'nope' }),
    ).toThrow(/resolvePath/)
  })

  it('throws when reissuePreviewToken is provided but not a function', () => {
    expect(() =>
      // @ts-expect-error — testing runtime guard
      createDraftModeRoutes({ previewSecret: 's', reissuePreviewToken: 'nope' }),
    ).toThrow(/reissuePreviewToken/)
  })
})
