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

  it('falls back to the flat path when only one of workspace/project is set', () => {
    expect(buildSchemaPath({ workspace: 'acme', dataset: 'production' })).toBe('/v1/schemas/production')
    expect(buildSchemaPath({ project: 'site', dataset: 'production' })).toBe('/v1/schemas/production')
  })

  it('url-encodes each segment', () => {
    expect(buildSchemaPath({ workspace: 'a b', project: 'c/d', dataset: 'e f' })).toBe(
      '/w/a%20b/p/c%2Fd/v1/schemas/e%20f',
    )
  })
})
