import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import { BarkparkAuthError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'tok',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('client.auth', () => {
  it('register POSTs {email,password} to /v1/auth/register (no scopePrefix)', async () => {
    let seenUrl = ''
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/register`, async ({ request }) => {
        seenUrl = request.url
        seenBody = await request.json()
        return HttpResponse.json({ user: { email: 'a@b.co', confirmed: false } }, { status: 201 })
      }),
    )
    const res = await createClient(baseConfig).auth.register('a@b.co', 'pw')
    expect(res.user.email).toBe('a@b.co')
    expect(new URL(seenUrl).pathname).toBe('/v1/auth/register')
    expect(seenBody).toEqual({ email: 'a@b.co', password: 'pw' })
  })

  it('login returns { token, user }; totpCode rides the body as totp_code', async () => {
    let seenBody: Record<string, unknown> = {}
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/login`, async ({ request }) => {
        seenBody = (await request.json()) as Record<string, unknown>
        return HttpResponse.json(
          { token: 'sess-xyz', user: { id: 'u1', email: 'a@b.co' } },
          { status: 201 },
        )
      }),
    )
    const session = await createClient(baseConfig).auth.login('a@b.co', 'pw', {
      totpCode: '123456',
    })
    expect(session.token).toBe('sess-xyz')
    expect(session.user.id).toBe('u1')
    expect(seenBody).toEqual({ email: 'a@b.co', password: 'pw', totp_code: '123456' })
  })

  it('me returns the user, or null on 401 (not authenticated)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/auth/me`, () =>
        HttpResponse.json({ user: { id: 'u1', email: 'a@b.co', confirmed: true, mfa: false } }),
      ),
    )
    expect((await createClient(baseConfig).auth.me())?.id).toBe('u1')

    server.use(
      http.get(`${TEST_BASE_URL}/v1/auth/me`, () =>
        HttpResponse.json(
          { error: { code: 'unauthorized', message: 'no session' } },
          { status: 401 },
        ),
      ),
    )
    expect(await createClient(baseConfig).auth.me()).toBeNull()
  })

  // The null-collapse discriminates (pds-bl-w49-core-auth-collapses-403-as-
  // unauthenticated): ONLY a genuine 401 reads as "no current user". A 403 —
  // the server's shape for forbidden, cors_forbidden and csrf_required alike —
  // is a refusal-to-answer and must propagate as the typed BarkparkAuthError,
  // never masquerade as an absent user.
  it.each([
    ['forbidden', 'token lacks permission'],
    ['cors_forbidden', 'origin not allowed for dataset'],
    ['csrf_required', 'missing x-requested-with header'],
  ])('me propagates a 403 %s as BarkparkAuthError instead of null', async (code, message) => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/auth/me`, () =>
        HttpResponse.json({ error: { code, message } }, { status: 403 }),
      ),
    )
    const err = await createClient(baseConfig)
      .auth.me()
      .then(
        () => {
          throw new Error('resolved — the 403 was swallowed as "no current user"')
        },
        (e: unknown) => e,
      )
    expect(err).toBeInstanceOf(BarkparkAuthError)
    expect((err as BarkparkAuthError).status).toBe(403)
    expect((err as BarkparkAuthError).serverCode).toBe(code)
  })

  it('logout DELETEs /v1/auth/logout', async () => {
    let seenMethod = ''
    server.use(
      http.delete(`${TEST_BASE_URL}/v1/auth/logout`, ({ request }) => {
        seenMethod = request.method
        return HttpResponse.json({ ok: true })
      }),
    )
    await createClient(baseConfig).auth.logout()
    expect(seenMethod).toBe('DELETE')
  })

  it('enrollMfa POSTs {password} and returns secret/otpauth_uri/qr_svg', async () => {
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/mfa/enroll`, async ({ request }) => {
        seenBody = await request.json()
        return HttpResponse.json({
          secret: 'BASE32SEC',
          otpauth_uri: 'otpauth://x',
          qr_svg: '<svg/>',
        })
      }),
    )
    const res = await createClient(baseConfig).auth.enrollMfa('pw')
    expect(res.secret).toBe('BASE32SEC')
    expect(res.otpauth_uri).toBe('otpauth://x')
    expect(seenBody).toEqual({ password: 'pw' })
  })

  it('verifyMfa POSTs {secret,code,password} and returns recovery_codes', async () => {
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/mfa/verify`, async ({ request }) => {
        seenBody = await request.json()
        return HttpResponse.json({ ok: true, recovery_codes: ['aaaa', 'bbbb'] })
      }),
    )
    const res = await createClient(baseConfig).auth.verifyMfa('BASE32SEC', '123456', 'pw')
    expect(res.recovery_codes).toEqual(['aaaa', 'bbbb'])
    expect(seenBody).toEqual({ secret: 'BASE32SEC', code: '123456', password: 'pw' })
  })

  it('disableMfa POSTs {password} to /v1/auth/mfa/disable', async () => {
    let seenBody: unknown
    let seenMethod = ''
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/mfa/disable`, async ({ request }) => {
        seenMethod = request.method
        seenBody = await request.json()
        return HttpResponse.json({ ok: true })
      }),
    )
    await createClient(baseConfig).auth.disableMfa('pw')
    expect(seenMethod).toBe('POST')
    expect(seenBody).toEqual({ password: 'pw' })
  })

  it('verifyEmail POSTs {token} to /v1/auth/verify-email', async () => {
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/verify-email`, async ({ request }) => {
        seenBody = await request.json()
        return HttpResponse.json({ ok: true })
      }),
    )
    await createClient(baseConfig).auth.verifyEmail('vtok')
    expect(seenBody).toEqual({ token: 'vtok' })
  })

  it('requestPasswordReset POSTs {email} to /v1/auth/request-reset', async () => {
    let seenBody: unknown
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/request-reset`, async ({ request }) => {
        seenBody = await request.json()
        return HttpResponse.json({ ok: true })
      }),
    )
    await createClient(baseConfig).auth.requestPasswordReset('a@b.co')
    expect(seenBody).toEqual({ email: 'a@b.co' })
  })

  it('resetPassword POSTs {token,password}; a bad token surfaces serverCode', async () => {
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/reset`, async ({ request }) => {
        const body = (await request.json()) as Record<string, unknown>
        if (body.token === 'good') return HttpResponse.json({ ok: true, sessionsRevoked: 3 })
        return HttpResponse.json(
          { error: { code: 'invalid_token', message: 'the reset link is invalid or expired' } },
          { status: 422 },
        )
      }),
    )
    const bp = createClient(baseConfig)
    await expect(bp.auth.resetPassword('good', 'newpw')).resolves.toEqual({ sessionsRevoked: 3 })
    await bp.auth.resetPassword('stale', 'newpw').then(
      () => expect.fail('expected throw on a stale token'),
      (err) => expect(err.serverCode).toBe('invalid_token'),
    )
  })

  it('resetPassword surfaces the sessionsRevoked count the server stamped', async () => {
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/reset`, () =>
        HttpResponse.json({ ok: true, sessionsRevoked: 7 }),
      ),
    )
    const bp = createClient(baseConfig)
    const receipt = await bp.auth.resetPassword('good', 'newpw')
    // The whole point of the row: the count must reach the caller, not be
    // discarded into a void return.
    expect(receipt.sessionsRevoked).toBe(7)
  })

  it('resetPassword keeps a counted zero distinct from an unreported count', async () => {
    // 0 is a MEASUREMENT — the server counted and there were no other sessions.
    server.use(
      http.post(`${TEST_BASE_URL}/v1/auth/reset`, () =>
        HttpResponse.json({ ok: true, sessionsRevoked: 0 }),
      ),
    )
    let bp = createClient(baseConfig)
    expect((await bp.auth.resetPassword('good', 'newpw')).sessionsRevoked).toBe(0)

    // null is an ABSENCE — a server that predates the field reported nothing.
    // Folding this into 0 would claim a measurement the server never made.
    server.use(http.post(`${TEST_BASE_URL}/v1/auth/reset`, () => HttpResponse.json({ ok: true })))
    bp = createClient(baseConfig)
    expect((await bp.auth.resetPassword('good', 'newpw')).sessionsRevoked).toBeNull()
  })
})
