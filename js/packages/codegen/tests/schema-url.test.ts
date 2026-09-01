import { describe, it, expect } from 'vitest'
import { buildSchemaPath } from '../src/index'

describe('buildSchemaPath', () => {
  it('builds the scoped path when workspace + project are provided', () => {
    expect(buildSchemaPath({ workspace: 'acme', project: 'site', dataset: 'production' })).toBe(
      '/w/acme/p/site/v1/schemas/production',
    )
  })

  it('falls back to the flat path when both are absent (back-compat)', () => {
    expect(buildSchemaPath({ dataset: 'production' })).toBe('/v1/schemas/production')
  })

  // Previously this suite PINNED the fail-open: a half-set pair returned the
  // flat '/v1/schemas/production'. That is the defect, not the contract — the
  // caller asked for a scoped read and silently got an unscoped one, which
  // `fetchSchema` then sent their bearer token to. Both-or-neither now, matching
  // `@barkpark/core`'s client.ts.
  it('refuses a half-set pair instead of falling back to the flat path', () => {
    expect(() => buildSchemaPath({ workspace: 'acme', dataset: 'production' })).toThrow(
      /workspace and project must be set together/,
    )
    expect(() => buildSchemaPath({ project: 'site', dataset: 'production' })).toThrow(
      /workspace and project must be set together/,
    )
  })

  // `exactOptionalPropertyTypes` stops TypeScript callers from writing an
  // explicit `undefined` half, so these casts stand in for the plain-JS callers
  // this package also ships to — the ones a type cannot warn. The guard is a
  // runtime check precisely because of them.
  type Opts = Parameters<typeof buildSchemaPath>[0]

  it('refuses an explicitly-undefined half — not just an absent one', () => {
    expect(() =>
      buildSchemaPath({
        workspace: 'acme',
        project: undefined,
        dataset: 'production',
      } as unknown as Opts),
    ).toThrow(/workspace and project must be set together/)
    expect(() =>
      buildSchemaPath({
        workspace: undefined,
        project: 'site',
        dataset: 'production',
      } as unknown as Opts),
    ).toThrow(/workspace and project must be set together/)
  })

  it('refuses an empty-string half — falsy, so the old `&&` guard dropped it too', () => {
    expect(() => buildSchemaPath({ workspace: '', project: 'site', dataset: 'production' })).toThrow(
      /workspace and project must be set together/,
    )
    expect(() => buildSchemaPath({ workspace: 'acme', project: '', dataset: 'production' })).toThrow(
      /workspace and project must be set together/,
    )
  })

  it('url-encodes each segment', () => {
    expect(buildSchemaPath({ workspace: 'a b', project: 'c/d', dataset: 'e f' })).toBe(
      '/w/a%20b/p/c%2Fd/v1/schemas/e%20f',
    )
  })
})
