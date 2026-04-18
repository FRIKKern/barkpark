import { describe, it, expect } from 'vitest'

describe('@barkpark/nextjs-query', () => {
  it('throws on import with Deferred to 1.1 message', async () => {
    await expect(import('../src/index')).rejects.toThrow(/Deferred to 1\.1/)
  })
})
