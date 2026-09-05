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
//
// ONE COPY, EVERY STARTER. This file used to import the guard twice — once per
// starter — because the two starters double-authored a byte-identical
// lib/resolve-server-token.ts. It is now authored once in templates/_shared/
// and scaffold() lays it under BOTH starters, so there is exactly one module to
// exercise. The per-starter half of the old coverage did not go away: the
// shadowing test below proves neither starter overrides it, and
// shared-template-composition.test.ts proves the generated blog and website
// apps both contain this file, byte-identical.
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { AVAILABLE_TEMPLATES, SHARED_TEMPLATE_DIR } from '../src/constants'
import { resolveServerToken } from '../templates/_shared/lib/resolve-server-token'

const TEMPLATES_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'templates')
const REL = path.join('lib', 'resolve-server-token.ts')

describe('the guard is shared, and no starter shadows it', () => {
  it('lives in the shared template source', () => {
    expect(existsSync(path.join(TEMPLATES_DIR, SHARED_TEMPLATE_DIR, REL))).toBe(true)
  })

  it.each([...AVAILABLE_TEMPLATES])('%s does not override it', (template) => {
    // A starter-local copy would win at scaffold time and silently escape every
    // assertion below — the exact drift the extraction removed.
    expect(existsSync(path.join(TEMPLATES_DIR, template, REL))).toBe(false)
  })
})

describe('shared resolveServerToken', () => {
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
