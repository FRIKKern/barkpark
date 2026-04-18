import { describe, it, expect } from 'vitest'
import { sha256Canonical, canonicalJson } from '../src/codegen/hash.js'

describe('sha256Canonical', () => {
  it('same object with different key order → equal hash', () => {
    const a = sha256Canonical({ a: 1, b: 2, c: 3 })
    const b = sha256Canonical({ c: 3, a: 1, b: 2 })
    expect(a).toBe(b)
  })

  it('{a:1} vs {a:2} → different hashes', () => {
    expect(sha256Canonical({ a: 1 })).not.toBe(sha256Canonical({ a: 2 }))
  })

  it('nested object sorts recursively', () => {
    const a = sha256Canonical({ outer: { a: 1, b: 2 }, list: [{ x: 1, y: 2 }] })
    const b = sha256Canonical({ list: [{ y: 2, x: 1 }], outer: { b: 2, a: 1 } })
    expect(a).toBe(b)
  })

  it('output is exactly 64 hex chars', () => {
    const h = sha256Canonical({ anything: 'value', n: 42 })
    expect(h).toMatch(/^[0-9a-f]{64}$/)
  })
})

describe('canonicalJson', () => {
  it('elides undefined object props', () => {
    expect(canonicalJson({ a: 1, b: undefined })).toBe('{"a":1}')
  })

  it('arrays preserve order', () => {
    expect(canonicalJson([3, 1, 2])).toBe('[3,1,2]')
  })

  it('undefined top-level → "null"', () => {
    expect(canonicalJson(undefined)).toBe('null')
  })

  it('sorts object keys', () => {
    expect(canonicalJson({ c: 3, a: 1, b: 2 })).toBe('{"a":1,"b":2,"c":3}')
  })
})
