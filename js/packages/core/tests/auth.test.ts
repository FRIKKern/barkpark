import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
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
})
