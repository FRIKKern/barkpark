import { describe, it, expect } from 'vitest'
import { isBarkparkError, BarkparkConflictError } from '../src/index'

describe('isBarkparkError', () => {
  it('accepts a real Barkpark error instance', () => {
    expect(isBarkparkError(new BarkparkConflictError('x'))).toBe(true)
  })

  it('narrows by code when a code is passed', () => {
    expect(isBarkparkError(new BarkparkConflictError('x'), 'BarkparkConflictError')).toBe(true)
    expect(isBarkparkError(new BarkparkConflictError('x'), 'BarkparkAuthError')).toBe(false)
  })

  it('matches a duck-typed cross-bundle copy (no instanceof)', () => {
    // A structurally-identical object from a hoisted duplicate class copy.
    expect(isBarkparkError({ code: 'BarkparkConflictError' }, 'BarkparkConflictError')).toBe(true)
  })

  it('rejects null and non-objects', () => {
    expect(isBarkparkError(null)).toBe(false)
    expect(isBarkparkError(undefined)).toBe(false)
    expect(isBarkparkError('BarkparkConflictError')).toBe(false)
  })

  it('rejects a plain Error (no string `code`)', () => {
    expect(isBarkparkError(new Error('x'))).toBe(false)
  })
})
