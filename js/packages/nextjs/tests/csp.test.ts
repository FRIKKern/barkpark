// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `@barkpark/nextjs/csp` — the reusable consumer CSP.
//
// These assertions are the ones the five hand-forked copies could not share.
// Each maps to a real divergence measured across
// blog-starter / website-starter / web (see the table in src/csp/index.ts):
//
//   • the SECURITY FLOOR is identical in every copy → pinned here once;
//   • `img-src`/`connect-src` widening is the ONLY thing that legitimately
//     varied → an option, proven not to leak into any other directive;
//   • `'unsafe-inline'` in `script-src` is the invariant every copy's comment
//     called load-bearing while NO copy actually enforced it → a throw, and the
//     mutation test for this file.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import {
  buildCspPolicy,
  generateNonce,
  createCspMiddleware,
  cspMatcher,
} from '../src/csp'

/** Split a policy string into a directive→sources map. */
function parse(policy: string): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const part of policy.split('; ')) {
    const [name, ...sources] = part.split(' ')
    if (name) out[name] = sources
  }
  return out
}

describe('buildCspPolicy — security floor', () => {
  const d = parse(buildCspPolicy('NONCE'))

  it('gates scripts on the nonce and never admits unsafe-inline', () => {
    expect(d['script-src']).toEqual([
      "'self'",
      "'nonce-NONCE'",
      "'strict-dynamic'",
    ])
    expect(d['script-src']).not.toContain("'unsafe-inline'")
    expect(d['script-src']).not.toContain("'unsafe-eval'")
  })

  it('pins the non-negotiable directives', () => {
    expect(d['default-src']).toEqual(["'self'"])
    expect(d['object-src']).toEqual(["'none'"])
    expect(d['base-uri']).toEqual(["'self'"])
    expect(d['frame-ancestors']).toEqual(["'none'"])
    expect(d['form-action']).toEqual(["'self'"])
  })

  it('keeps style-src unsafe-inline (Tailwind/Next inline style attributes)', () => {
    expect(d['style-src']).toContain("'unsafe-inline'")
  })
})

describe('buildCspPolicy — the variance the five forks encoded by hand', () => {
  it("website-starter's hosted hero images: img-src widens, nothing else moves", () => {
    const base = parse(buildCspPolicy('N'))
    const wide = parse(buildCspPolicy('N', { additional: { 'img-src': ['https:'] } }))
    expect(wide['img-src']).toEqual(["'self'", 'data:', 'blob:', 'https:'])
    for (const k of Object.keys(base)) {
      if (k === 'img-src') continue
      expect(wide[k], `${k} must not move when img-src widens`).toEqual(base[k])
    }
  })

  it("web/'s direct live-search socket: connect-src takes an exact origin", () => {
    const d = parse(
      buildCspPolicy('N', {
        additional: { 'connect-src': ['wss://api.barkpark.cloud'] },
      }),
    )
    expect(d['connect-src']).toEqual(["'self'", 'wss://api.barkpark.cloud'])
  })

  it('a source the base policy already carries is not repeated', () => {
    const d = parse(buildCspPolicy('N', { additional: { 'img-src': ['blob:'] } }))
    expect(d['img-src']).toEqual(["'self'", 'data:', 'blob:'])
  })

  it('a widened directive the base never named is EMITTED, not lost to default-src', () => {
    const d = parse(
      buildCspPolicy('N', { additional: { 'worker-src': ['blob:'] } }),
    )
    expect(d['worker-src']).toEqual(["'self'", 'blob:'])
  })

  it('report-uri is appended without relaxing anything', () => {
    const policy = buildCspPolicy('N', { reportUri: '/csp-report' })
    expect(policy.endsWith('; report-uri /csp-report')).toBe(true)
    const d = parse(policy)
    expect(d['script-src']).not.toContain("'unsafe-inline'")
  })
})

describe("buildCspPolicy — script-src 'unsafe-inline' is refused, not merged", () => {
  // THE mutation target for this file: delete the FORBIDDEN_SCRIPT_SOURCES
  // guard in src/csp/index.ts and this suite reds — the policy would otherwise
  // silently emit a nonce alongside 'unsafe-inline', which conformant browsers
  // resolve by IGNORING unsafe-inline and legacy ones resolve by honouring it.
  // Either way the caller believes something false.
  for (const bad of ["'unsafe-inline'", "'unsafe-eval'"]) {
    it(`throws on ${bad}`, () => {
      expect(() =>
        buildCspPolicy('N', { additional: { 'script-src': [bad] } }),
      ).toThrow(/refusing to add/)
    })
  }

  it('still accepts a legitimate script-src host', () => {
    const d = parse(
      buildCspPolicy('N', {
        additional: { 'script-src': ['https://cdn.example.com'] },
      }),
    )
    expect(d['script-src']).toContain('https://cdn.example.com')
    expect(d['script-src']).toContain("'nonce-N'")
  })
})

describe('generateNonce', () => {
  it('is 128 bits of base64, fresh per call', () => {
    const seen = new Set<string>()
    for (let i = 0; i < 200; i++) {
      const n = generateNonce()
      expect(n).toMatch(/^[A-Za-z0-9+/]+={0,2}$/)
      // 16 bytes → 24 base64 chars incl. padding.
      expect(atob(n).length).toBe(16)
      seen.add(n)
    }
    expect(seen.size).toBe(200)
  })
})

describe('createCspMiddleware — the two-header pattern', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('stamps the SAME nonce on the forwarded request AND the response', async () => {
    const { NextRequest } = await import('next/server')
    const middleware = createCspMiddleware()
    const res = middleware(new NextRequest('https://example.com/blog/hello'))

    const responsePolicy = res.headers.get('content-security-policy')
    expect(responsePolicy).toBeTruthy()

    // Next surfaces the forwarded request headers on the middleware response
    // under `x-middleware-request-*`; that is the copy the App-Router renderer
    // reads the nonce from. Without it, framework bootstrap scripts go
    // un-nonced and hydration dies into a static shell.
    const forwardedNonce =
      res.headers.get('x-middleware-request-x-nonce') ??
      res.headers.get('x-nonce')
    expect(forwardedNonce, 'nonce must be forwarded on the REQUEST').toBeTruthy()

    const forwardedPolicy =
      res.headers.get('x-middleware-request-content-security-policy') ??
      responsePolicy
    expect(forwardedPolicy).toBe(responsePolicy)
    expect(responsePolicy).toContain(`'nonce-${forwardedNonce}'`)
  })

  it('mints a DIFFERENT nonce per request', async () => {
    const { NextRequest } = await import('next/server')
    const middleware = createCspMiddleware()
    const a = middleware(new NextRequest('https://example.com/a'))
    const b = middleware(new NextRequest('https://example.com/b'))
    expect(a.headers.get('content-security-policy')).not.toBe(
      b.headers.get('content-security-policy'),
    )
  })

  it('carries the caller options into the emitted policy', async () => {
    const { NextRequest } = await import('next/server')
    const middleware = createCspMiddleware({
      additional: { 'img-src': ['https:'] },
    })
    const res = middleware(new NextRequest('https://example.com/'))
    expect(res.headers.get('content-security-policy')).toContain(
      "img-src 'self' data: blob: https:",
    )
  })
})

describe('cspMatcher', () => {
  it('skips the paths that never render app HTML, and prefetch/RSC requests', () => {
    expect(cspMatcher).toHaveLength(1)
    const m = cspMatcher[0]
    expect(m.source).toBe('/((?!_next/static|_next/image|favicon.ico|api).*)')
    expect(m.missing.map((x) => x.key)).toEqual([
      'next-router-prefetch',
      'purpose',
    ])
  })

  it('the source regex admits app routes and rejects the excluded ones', () => {
    const re = new RegExp(`^${cspMatcher[0].source}$`)
    expect(re.test('/blog/hello')).toBe(true)
    expect(re.test('/')).toBe(true)
    expect(re.test('/_next/static/chunk.js')).toBe(false)
    expect(re.test('/api/webhook')).toBe(false)
    expect(re.test('/favicon.ico')).toBe(false)
  })
})
