import { describe, it, expect } from 'vitest'
import { createClient, scopePrefix } from '../src/client'
import { BarkparkValidationError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

const validConfig: BarkparkClientConfig = {
  projectUrl: 'http://localhost:4000',
  dataset: 'production',
  apiVersion: '2026-04-01',
}

describe('createClient', () => {
  it('returns a frozen config', () => {
    const c = createClient(validConfig)
    expect(c.config.dataset).toBe('production')
    expect(() => {
      ;(c.config as { dataset: string }).dataset = 'x'
    }).toThrow()
  })

  it('validates projectUrl (must be absolute http)', () => {
    expect(() => createClient({ ...validConfig, projectUrl: 'not-a-url' })).toThrow(
      BarkparkValidationError,
    )
  })

  it('validates apiVersion YYYY-MM-DD', () => {
    expect(() =>
      createClient({ ...validConfig, apiVersion: 'v1' as BarkparkClientConfig['apiVersion'] }),
    ).toThrow(BarkparkValidationError)
  })

  it('validates dataset charset', () => {
    expect(() => createClient({ ...validConfig, dataset: 'Production' })).toThrow(
      BarkparkValidationError,
    )
  })

  it('withConfig returns a new client with merged config', () => {
    const c1 = createClient(validConfig)
    const c2 = c1.withConfig({ perspective: 'drafts' })
    expect(c2.config.perspective).toBe('drafts')
    expect(c1.config.perspective).toBeUndefined()
    expect(c2).not.toBe(c1)
  })

  // --- workspace / project config (w1-s9) ----------------------------------

  it('accepts valid workspace + project slugs', () => {
    const c = createClient({ ...validConfig, workspace: 'acme', project: 'blog-1' })
    expect(c.config.workspace).toBe('acme')
    expect(c.config.project).toBe('blog-1')
  })

  it('is back-compat: workspace + project both omitted', () => {
    const c = createClient(validConfig)
    expect(c.config.workspace).toBeUndefined()
    expect(c.config.project).toBeUndefined()
  })

  it('is back-compat: workspace present without project', () => {
    const c = createClient({ ...validConfig, workspace: 'acme' })
    expect(c.config.workspace).toBe('acme')
    expect(c.config.project).toBeUndefined()
  })

  it('rejects a bad workspace slug (uppercase)', () => {
    expect(() => createClient({ ...validConfig, workspace: 'Acme' })).toThrow(
      BarkparkValidationError,
    )
  })

  it('rejects a bad workspace slug (leading dash)', () => {
    expect(() => createClient({ ...validConfig, workspace: '-acme' })).toThrow(
      BarkparkValidationError,
    )
  })

  it('rejects an empty workspace slug', () => {
    expect(() => createClient({ ...validConfig, workspace: '' })).toThrow(
      BarkparkValidationError,
    )
  })

  it('rejects a bad project slug (space)', () => {
    expect(() => createClient({ ...validConfig, workspace: 'acme', project: 'my blog' })).toThrow(
      BarkparkValidationError,
    )
  })
})

describe('scopePrefix', () => {
  const base: BarkparkClientConfig = {
    projectUrl: 'http://localhost:4000',
    dataset: 'production',
    apiVersion: '2026-04-01',
  }

  it('returns /w/../p/.. when BOTH workspace and project are set', () => {
    expect(scopePrefix({ ...base, workspace: 'acme', project: 'blog' })).toBe('/w/acme/p/blog')
  })

  it('returns "" when neither is set (flat)', () => {
    expect(scopePrefix(base)).toBe('')
  })

  it('returns "" when only workspace is set', () => {
    expect(scopePrefix({ ...base, workspace: 'acme' })).toBe('')
  })

  it('returns "" when only project is set', () => {
    expect(scopePrefix({ ...base, project: 'blog' })).toBe('')
  })

  it('returns "" when a field is present but empty', () => {
    expect(scopePrefix({ ...base, workspace: 'acme', project: '' })).toBe('')
  })
})
