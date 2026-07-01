import { describe, it, expect } from 'vitest'
import {
  isBarkparkError,
  BarkparkConflictError,
  BarkparkRateLimitError,
  BarkparkValidationError,
} from '../src/index'

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

  it('narrows to the subclass so its extra fields are reachable without a cast', () => {
    const e: unknown = new BarkparkRateLimitError('slow down', { retryAfterMs: 1200 })
    if (isBarkparkError(e, 'BarkparkRateLimitError')) {
      // Type-level assertion: `e` is now BarkparkRateLimitError, so a
      // subclass-only field typechecks with no `as` cast. If the overloads
      // regressed to the abstract base, `tsc --noEmit` would fail here.
      const retry: number | undefined = e.retryAfterMs
      expect(retry).toBe(1200)
    } else {
      throw new Error('guard should have matched')
    }

    const v: unknown = new BarkparkValidationError('bad', { issues: [{ field: 'title' }] })
    if (isBarkparkError(v, 'BarkparkValidationError')) {
      const issues: unknown[] | undefined = v.issues
      expect(issues).toEqual([{ field: 'title' }])
    } else {
      throw new Error('guard should have matched')
    }

    // Conflict subclass carries recovery fields.
    const c: unknown = new BarkparkConflictError('collision', { serverEtag: 'W/"3"' })
    if (isBarkparkError(c, 'BarkparkConflictError')) {
      const etag: string | undefined = c.serverEtag
      expect(etag).toBe('W/"3"')
    } else {
      throw new Error('guard should have matched')
    }
  })
})
