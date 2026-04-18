import { describe, it, expect } from 'vitest'
import * as mod from '../src/index'

describe('@barkpark/core scaffold', () => {
  it('exports createClient', () => {
    expect(typeof mod.createClient).toBe('function')
  })
  it('exports error classes', () => {
    expect(new mod.BarkparkError('x')).toBeInstanceOf(Error)
    expect(new mod.BarkparkSchemaMismatchError('x').name).toBe('BarkparkSchemaMismatchError')
  })
  it('typedClient is identity', () => {
    const c = { a: 1 }
    expect(mod.typedClient(c)).toBe(c)
  })
})
