import { describe, it, expect } from 'vitest'

describe('core runs under workerd', () => {
  it('has global fetch', () => {
    expect(typeof globalThis.fetch).toBe('function')
  })
})
