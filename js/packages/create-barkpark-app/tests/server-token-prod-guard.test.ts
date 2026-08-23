// wtc-backlog-server-token-prod-guard: both starter templates' lib/barkpark.ts
// used to default serverToken to `BARKPARK_SERVER_TOKEN ?? 'barkpark-dev-token'`
// unconditionally — a missing env var in production silently shipped the dev
// token and deferred the misconfig to a runtime 401 on every server-side
// fetch. `resolveServerToken` now throws at module load when the var is
// unset AND NODE_ENV==='production' (the README already forbids the dev
// token in prod; this enforces it instead of documenting it and hoping).
//
// `resolveServerToken` is intentionally dependency-free (no 'server-only',
// no @barkpark/*) so it's importable straight from the template source here,
// unlike `lib/barkpark.ts` itself which pulls in 'server-only' and
// '@barkpark/nextjs/server' — packages this test package doesn't (and
// shouldn't need to) install.
import { describe, expect, it } from 'vitest'
import { resolveServerToken as websiteResolveServerToken } from '../templates/website-starter/lib/resolve-server-token'
import { resolveServerToken as blogResolveServerToken } from '../templates/blog-starter/lib/resolve-server-token'

describe.each([
  ['website-starter', websiteResolveServerToken],
  ['blog-starter', blogResolveServerToken],
])('%s resolveServerToken', (_name, resolveServerToken) => {
  it('returns the configured token when set, in any environment', () => {
    expect(resolveServerToken({ BARKPARK_SERVER_TOKEN: 'real-token', NODE_ENV: 'production' })).toBe(
      'real-token',
    )
    expect(resolveServerToken({ BARKPARK_SERVER_TOKEN: 'real-token', NODE_ENV: 'development' })).toBe(
      'real-token',
    )
  })

  it('falls back to the dev token outside production', () => {
    expect(resolveServerToken({ NODE_ENV: 'development' })).toBe('barkpark-dev-token')
    expect(resolveServerToken({ NODE_ENV: 'test' })).toBe('barkpark-dev-token')
    expect(resolveServerToken({})).toBe('barkpark-dev-token')
  })

  it('throws instead of falling back to the dev token in production', () => {
    expect(() => resolveServerToken({ NODE_ENV: 'production' })).toThrow(/BARKPARK_SERVER_TOKEN/)
  })

  it('throws on an empty-string token in production (falsy, not just unset)', () => {
    expect(() => resolveServerToken({ BARKPARK_SERVER_TOKEN: '', NODE_ENV: 'production' })).toThrow(
      /BARKPARK_SERVER_TOKEN/,
    )
  })
})
