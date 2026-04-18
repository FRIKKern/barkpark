import { describe, it, expect } from 'vitest'
import { createClient } from '../src/client'
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
})
