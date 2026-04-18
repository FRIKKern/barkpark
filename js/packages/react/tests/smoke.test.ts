import { describe, it, expect } from 'vitest'
import { PortableText, BarkparkImage, BarkparkReference } from '../src/index'

describe('@barkpark/react scaffold', () => {
  it('exports three components as functions', () => {
    expect(typeof PortableText).toBe('function')
    expect(typeof BarkparkImage).toBe('function')
    expect(typeof BarkparkReference).toBe('function')
  })
})
