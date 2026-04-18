import { describe, it, expect } from 'vitest'

describe('@barkpark/groq', () => {
  it('throws on import', async () => {
    await expect(import('../src/index')).rejects.toThrow(/not implemented in 1.0/)
  })
})
