/**
 * SECRET-LEAK regression guard — @barkpark/nextjs serverToken second store.
 *
 * The nextjs SDK carries a SECOND token the Go CLI never had: `serverToken`
 * (server-only Bearer, "MUST never reach the browser bundle"). It is SAFE BY
 * CONSTRUCTION: `defineLive(cfg)` returns `{ barkparkFetch }` and
 * `createBarkparkServer(cfg)` returns `{ ...inner, defineLive }` — the token is
 * closure-captured inside `cfg` and is NEVER an enumerable field of any returned
 * object. So `JSON.stringify(server)` serializes to the empty-object shape and
 * the token cannot reach a consumer's JSON.stringify / util.inspect / SSR dump /
 * React-devtools tree.
 *
 * This file LOCKS that verdict: with a distinctive sentinel serverToken AND a
 * distinctive client token, neither string may surface in JSON.stringify(server),
 * util.inspect(server, { depth }), or Object.keys(server). A future refactor that
 * accidentally hangs serverToken on the returned object turns these RED.
 *
 * Vector (4) of the JS secret-leak class (TOKEN IN SERIALIZED STATE), nextjs arm.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { inspect } from 'node:util'

const { draftModeMock } = vi.hoisted(() => ({
  draftModeMock: vi.fn(async () => ({ isEnabled: false })),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

import { createBarkparkServer, defineLive } from '../src/server/index'
import type { BarkparkServerConfig } from '../src/server/index'

// Distinctive sentinels — long, unlikely to collide with any incidental substring.
const SENTINEL_SERVER_TOKEN = 'SENTINEL-SERVER-TOKEN-a1b2c3d4e5f6-do-not-leak'
const SENTINEL_CLIENT_TOKEN = 'SENTINEL-CLIENT-TOKEN-9z8y7x6w5v4u-do-not-leak'

interface FakeClient {
  config: {
    projectUrl: string
    dataset: string
    apiVersion: string
    // A real client may carry its own token; put a sentinel here too so the
    // guard also proves the client token never rides out via the server object.
    token: string
  }
}

function makeClient(): FakeClient {
  return {
    config: {
      projectUrl: 'http://localhost:4000',
      dataset: 'production',
      apiVersion: '2026-01-01',
      token: SENTINEL_CLIENT_TOKEN,
    },
  }
}

function makeCfg(): BarkparkServerConfig {
  // unsafe cast — test fake client supplies only what server core reads
  return {
    client: makeClient() as unknown as BarkparkServerConfig['client'],
    serverToken: SENTINEL_SERVER_TOKEN,
  }
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

function assertNoTokenLeak(label: string, server: object): void {
  // (a) JSON.stringify — SSR serialization / structured-clone-ish path.
  const json = JSON.stringify(server)
  expect(json, `${label}: JSON.stringify must not contain serverToken`).not.toContain(
    SENTINEL_SERVER_TOKEN,
  )
  expect(json, `${label}: JSON.stringify must not contain client token`).not.toContain(
    SENTINEL_CLIENT_TOKEN,
  )
  // The returned bundle is functions only — it serializes to the empty object.
  expect(json, `${label}: returned bundle serializes to '{}'`).toBe('{}')

  // (b) util.inspect — the console.log / devtools inspection path (deep).
  const inspected = inspect(server, { depth: 6, showHidden: false })
  expect(inspected, `${label}: util.inspect must not contain serverToken`).not.toContain(
    SENTINEL_SERVER_TOKEN,
  )
  expect(inspected, `${label}: util.inspect must not contain client token`).not.toContain(
    SENTINEL_CLIENT_TOKEN,
  )

  // (c) Object.keys — no enumerable 'serverToken' (nor 'client') property.
  const keys = Object.keys(server)
  expect(keys, `${label}: no enumerable 'serverToken' key`).not.toContain('serverToken')
  expect(keys, `${label}: no enumerable 'client' key`).not.toContain('client')
}

describe('serverToken never surfaces in a serialized server object (SAFE-by-construction guard)', () => {
  it('createBarkparkServer(cfg) — no token in JSON.stringify / util.inspect / Object.keys', () => {
    const server = createBarkparkServer(makeCfg())
    assertNoTokenLeak('createBarkparkServer', server)
    // Sanity: it really is the server bundle we think it is (functions only).
    expect(Object.keys(server).sort()).toEqual(['barkparkFetch', 'defineLive'])
  })

  it('defineLive(cfg) — no token in JSON.stringify / util.inspect / Object.keys', () => {
    const live = defineLive(makeCfg())
    assertNoTokenLeak('defineLive', live)
    expect(Object.keys(live)).toEqual(['barkparkFetch'])
  })

  it('the sentinels are genuinely present in the config the server was built from (guard is not vacuous)', () => {
    // If the sentinels somehow were empty/undefined the leak assertions above
    // would pass vacuously. Prove the config actually carries them.
    const cfg = makeCfg()
    expect(cfg.serverToken).toBe(SENTINEL_SERVER_TOKEN)
    expect(
      (cfg.client as unknown as FakeClient).config.token,
    ).toBe(SENTINEL_CLIENT_TOKEN)
  })
})
