import { describe, it, expect } from 'vitest'
import { createClient } from '../src'

describe('core loads under browser', () => {
  it('has global fetch and ReadableStream', () => {
    expect(typeof globalThis.fetch).toBe('function')
    expect(typeof globalThis.ReadableStream).toBe('function')
  })

  it('createClient returns a client with the full method surface', () => {
    const client = createClient({
      projectUrl: 'https://example.com',
      dataset: 'production',
      apiVersion: '2026-04-01',
    })
    for (const method of [
      'doc',
      'docs',
      'patch',
      'transaction',
      'publish',
      'unpublish',
      'listen',
      'fetchRaw',
      'withConfig',
    ] as const) {
      expect(typeof client[method]).toBe('function')
    }
  })
})
