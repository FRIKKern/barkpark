import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  MAX_PAGE_LINKS,
  pageCount,
  pageWindow,
  resolvePageParam,
} from '../templates/blog-starter/lib/page-param'

/**
 * Shipped bug: blog-starter's home page clamped only the LOWER bound of the
 * anonymous, caller-controlled `?page=`:
 *
 *   const pageNum = Math.max(1, Math.floor(Number(sp.page ?? '1') || 1))
 *
 * and then handed the result to <Pagination>, a SERVER component whose
 *
 *   Array.from({ length: totalPages }, (_, i) => i + 1)
 *
 * materialises one <Link> per page on the server, per request. Measured against
 * the shipped expression:
 *
 *   ?page=20000   -> pageNum 20000 -> 20 000 server-rendered <Link> elements
 *   ?page=Infinity -> pageNum Infinity -> RangeError: Invalid array length (500)
 *   ?page=1e309    -> overflows to Infinity -> same RangeError
 *
 * `|| 1` looks like a guard but only catches FALSY `Number()` results (NaN, 0,
 * '', -0). `Infinity` is truthy, so it walks straight through. `Number.isFinite`
 * is the guard that idiom is missing, and an upper clamp is the other half.
 *
 * This file imports the TEMPLATE's own modules — not a copy of their logic — so
 * it cannot go green against a template that has drifted back.
 */

const HERE = path.dirname(fileURLToPath(import.meta.url))
const BLOG = path.resolve(HERE, '..', 'templates', 'blog-starter')

describe('resolvePageParam: the lower clamp still holds', () => {
  it.each([
    ['undefined (no ?page=)', undefined],
    ['empty string', ''],
    ['whitespace', '   '],
    ['non-numeric', 'abc'],
    ['zero', '0'],
    ['negative', '-5'],
    ['NaN literal', 'NaN'],
  ])('%s -> page 1', (_label, raw) => {
    expect(resolvePageParam(raw as string | undefined, 10)).toBe(1)
  })

  it('an in-range page passes through', () => {
    expect(resolvePageParam('3', 10)).toBe(3)
  })

  it('a fractional page floors', () => {
    expect(resolvePageParam('3.9', 10)).toBe(3)
  })
})

describe('resolvePageParam: the UPPER clamp — the half that was missing', () => {
  it('?page=20000 clamps to the real page count, not the URL', () => {
    expect(resolvePageParam('20000', 4)).toBe(4)
  })

  it('?page=Infinity is rejected as non-finite, NOT admitted as truthy', () => {
    // The exact input the `|| 1` idiom let through.
    expect(resolvePageParam('Infinity', 4)).toBe(1)
    expect(Number('Infinity')).toBe(Infinity)
    expect(Boolean(Number('Infinity'))).toBe(true) // ...which is why `|| 1` missed it
  })

  it('?page=-Infinity and ?page=1e309 (overflow) are rejected too', () => {
    expect(resolvePageParam('-Infinity', 4)).toBe(1)
    expect(Number('1e309')).toBe(Infinity)
    expect(resolvePageParam('1e309', 4)).toBe(1)
  })

  it('a repeated param (?page=2&page=9000) takes the first and still clamps', () => {
    expect(resolvePageParam(['2', '9000'], 4)).toBe(2)
    expect(resolvePageParam(['9000', '2'], 4)).toBe(4)
  })

  it('a non-finite totalPages cannot widen the clamp', () => {
    expect(resolvePageParam('20000', Infinity)).toBe(1)
    expect(resolvePageParam('20000', Number.NaN)).toBe(1)
  })

  it('the result is ALWAYS a finite integer in [1, totalPages]', () => {
    const inputs = ['0', '1', '2.5', '-7', 'abc', 'Infinity', '1e309', '20000', '', 'NaN']
    for (const raw of inputs) {
      const n = resolvePageParam(raw, 4)
      expect(Number.isInteger(n)).toBe(true)
      expect(n).toBeGreaterThanOrEqual(1)
      expect(n).toBeLessThanOrEqual(4)
    }
  })
})

describe('pageCount', () => {
  it('is 1 for an empty corpus (never 0 — page 1 always exists)', () => {
    expect(pageCount(0, 5)).toBe(1)
  })

  it('rounds up a partial last page', () => {
    expect(pageCount(11, 5)).toBe(3)
    expect(pageCount(10, 5)).toBe(2)
  })

  it('degrades to 1 on nonsense rather than producing Infinity', () => {
    expect(pageCount(Infinity, 5)).toBe(1)
    expect(pageCount(10, 0)).toBe(1)
    expect(pageCount(Number.NaN, 5)).toBe(1)
  })
})

describe('pageWindow: the renderer can never be handed an unbounded length', () => {
  it('caps the number of links regardless of how large totalPages is', () => {
    expect(pageWindow(1, 20000).length).toBe(MAX_PAGE_LINKS)
    expect(pageWindow(10000, 20000).length).toBe(MAX_PAGE_LINKS)
  })

  it('returns a short window for a small corpus (no padding)', () => {
    expect(pageWindow(1, 3)).toEqual([1, 2, 3])
    expect(pageWindow(1, 1)).toEqual([1])
  })

  it('stays inside [1, totalPages] at both edges', () => {
    const first = pageWindow(1, 100)
    expect(first[0]).toBe(1)
    const last = pageWindow(100, 100)
    expect(last[last.length - 1]).toBe(100)
    expect(last[0]).toBeGreaterThanOrEqual(1)
  })

  it('survives Infinity without throwing RangeError — the original 500', () => {
    // Array.from({length: Infinity}) throws "RangeError: Invalid array length".
    expect(() => Array.from({ length: Infinity as unknown as number })).toThrow(RangeError)
    expect(() => pageWindow(1, Infinity)).not.toThrow()
    expect(pageWindow(1, Infinity)).toEqual([1])
    expect(() => pageWindow(Infinity, 10)).not.toThrow()
    expect(pageWindow(Infinity, 10).length).toBeLessThanOrEqual(MAX_PAGE_LINKS)
  })

  it('centres on the current page', () => {
    const w = pageWindow(50, 100, 5)
    expect(w).toEqual([48, 49, 50, 51, 52])
  })
})

describe('the template actually USES the clamp (a pure module nobody calls is not a fix)', () => {
  it('app/page.tsx resolves ?page= through resolvePageParam and drops the bare `|| 1` idiom', async () => {
    const src = await fs.readFile(path.join(BLOG, 'app', 'page.tsx'), 'utf8')
    expect(src.length).toBeGreaterThan(200) // the read is real
    expect(src).toContain('resolvePageParam')
    expect(src).toContain('pageCount')
    // The exact shipped defect, byte-for-byte.
    expect(src).not.toContain("Math.max(1, Math.floor(Number(sp.page ?? '1') || 1))")
    // And the class of it: no `Number(...) || ` fallback on searchParams input.
    expect(/Number\([^)]*sp\.[^)]*\)\s*\|\|/.test(src)).toBe(false)
  })

  it('components/Pagination.tsx bounds its Array.from through pageWindow', async () => {
    const src = await fs.readFile(path.join(BLOG, 'app', 'components', 'Pagination.tsx'), 'utf8')
    expect(src.length).toBeGreaterThan(200)
    expect(src).toContain('pageWindow')
    // The unbounded length expression must be gone from the component.
    expect(src).not.toContain('Array.from({ length: totalPages }')
  })
})
