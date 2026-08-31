// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `buildCspPolicy`'s `additional` values, when a consumer passes a bare string.
//
// Same shape as the `tags` hazard in src/server/core.ts and the `sync_tags` /
// `paths` hazard the write side documents in src/revalidate/index.ts: a bare
// string is iterable, so `additional: { 'script-src': "'unsafe-inline'" }`
// walked the string CHARACTER by character. The FORBIDDEN_SCRIPT_SOURCES throw
// compared single characters against the forbidden list and never fired, and
// the merge loop appended `'`, `u`, `n`, `s`, … as separate sources.
//
// The resulting header is not actually WEAKER — a single character is not a
// valid CSP source expression, so browsers drop them — so this is a FAILED
// CONTROL, not an open hole. It matters because the module's own note justifies
// the runtime check by saying the package "ships CJS/ESM consumable from plain
// JS, where no type exists at all" — i.e. the check was defeated in precisely
// the scenario it was written for.

import { describe, it, expect } from 'vitest'
import { buildCspPolicy } from '../src/csp'

/** Split a policy string into a directive→sources map. */
function parse(policy: string): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const part of policy.split('; ')) {
    const [name, ...sources] = part.split(' ')
    if (name) out[name] = sources
  }
  return out
}

describe('buildCspPolicy — a bare-string `additional` value', () => {
  it('fires the forbidden-source throw for a bare-string script-src', () => {
    expect(() =>
      buildCspPolicy('N', {
        additional: { 'script-src': "'unsafe-inline'" as unknown as readonly string[] },
      }),
    ).toThrow(/unsafe-inline/)
  })

  it('fires the forbidden-source throw for a bare-string unsafe-eval', () => {
    expect(() =>
      buildCspPolicy('N', {
        additional: { 'script-src': "'unsafe-eval'" as unknown as readonly string[] },
      }),
    ).toThrow(/unsafe-eval/)
  })

  it('appends a bare-string widening as ONE source, not as characters', () => {
    const d = parse(
      buildCspPolicy('N', {
        additional: { 'img-src': 'https:' as unknown as readonly string[] },
      }),
    )
    expect(d['img-src']).toEqual(["'self'", 'data:', 'blob:', 'https:'])
    expect(d['img-src']).not.toContain('h')
    expect(d['img-src']).not.toContain(':')
  })

  it('appends a bare-string widening to a directive the base policy never named', () => {
    const d = parse(
      buildCspPolicy('N', {
        additional: { 'worker-src': 'blob:' as unknown as readonly string[] },
      }),
    )
    expect(d['worker-src']).toEqual(["'self'", 'blob:'])
    expect(d['worker-src']).not.toContain('b')
  })

  it('still accepts a normal array widening', () => {
    const d = parse(buildCspPolicy('N', { additional: { 'connect-src': ['wss://x.example'] } }))
    expect(d['connect-src']).toEqual(["'self'", 'wss://x.example'])
  })
})
