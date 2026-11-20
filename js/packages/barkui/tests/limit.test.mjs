import { describe, expect, it } from 'vitest'
import { limit } from '../check/limit.mjs'

describe('limit', () => {
  it('fails a promise that never settles with the name of what it was waiting for', async () => {
    const t0 = Date.now()
    await expect(limit(new Promise(() => {}), 50, 'step "Space activates it"')).rejects.toThrow('step "Space activates it" timed out after 0.05s')
    expect(Date.now() - t0).toBeLessThan(1000)
  })

  it('passes a settled value through', async () => {
    await expect(limit(Promise.resolve(7), 50, 'x')).resolves.toBe(7)
  })
})
