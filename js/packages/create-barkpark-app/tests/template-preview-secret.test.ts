import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash, timingSafeEqual } from 'node:crypto'

import { constantTimeEqual } from '../templates/blog-starter/lib/constant-time-equal'

/**
 * blog-starter's `/api/preview` gated `draftMode().enable()` — the only thing
 * between an anonymous GET and reading a deployed site's unpublished content —
 * with `url.searchParams.get('secret') !== secret`.
 *
 * `!==` on strings compares LENGTH first and then bytes with an early exit, so
 * both the secret's length and the position of the first wrong byte are
 * observable in the comparison's duration. Everywhere ELSE in this repo that
 * compares a secret already uses `node:crypto`'s `timingSafeEqual`:
 * `@barkpark/nextjs`'s `createDraftModeRoutes` (src/draft-mode/index.ts),
 * `@barkpark/core`'s `timingSafeEqual` (src/webhook.ts), and web/'s webhook route.
 * This route was the one holdout — and it is a TEMPLATE, copied into every
 * generated project, including ones that will run on a long-lived server rather
 * than behind a serverless edge.
 *
 * `timingSafeEqual` THROWS RangeError on a length mismatch, so it cannot take raw
 * user input; both sides are SHA-256'd to a fixed 32 bytes first, which also
 * removes the length side-channel a `a.length !== b.length` pre-check would keep.
 */

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROUTE = path.resolve(
  HERE,
  '..',
  'templates',
  'blog-starter',
  'app',
  'api',
  'preview',
  'route.ts',
)

describe('constantTimeEqual: correctness first', () => {
  it('accepts the matching secret', () => {
    expect(constantTimeEqual('s3cret-value', 's3cret-value')).toBe(true)
  })

  it('rejects a wrong secret of the SAME length', () => {
    expect(constantTimeEqual('s3cret-valuX', 's3cret-value')).toBe(false)
  })

  it('rejects a wrong secret of a DIFFERENT length without throwing', () => {
    // The whole reason both sides are hashed: raw timingSafeEqual throws here.
    expect(() =>
      timingSafeEqual(Buffer.from('short'), Buffer.from('a much longer secret')),
    ).toThrow(RangeError)
    expect(() => constantTimeEqual('short', 'a much longer secret')).not.toThrow()
    expect(constantTimeEqual('short', 'a much longer secret')).toBe(false)
    expect(constantTimeEqual('a much longer secret', 'short')).toBe(false)
  })

  it('fails CLOSED on absent or empty input', () => {
    expect(constantTimeEqual(null, 'secret')).toBe(false)
    expect(constantTimeEqual(undefined, 'secret')).toBe(false)
    expect(constantTimeEqual('', 'secret')).toBe(false)
    // The case that matters most: an UNSET env var must not be matchable.
    expect(constantTimeEqual('', '')).toBe(false)
    expect(constantTimeEqual('anything', undefined)).toBe(false)
    expect(constantTimeEqual(null, null)).toBe(false)
  })

  it('handles multi-byte UTF-8 secrets', () => {
    const a = 'passord-æøå-\u{1f511}'
    expect(constantTimeEqual(a, 'passord-æøå-\u{1f511}')).toBe(true)
    expect(constantTimeEqual(a, 'passord-æøå-\u{1f512}')).toBe(false)
  })

  it('compares fixed-width digests, so the compared length is secret-independent', () => {
    // Both a 5-char and a 500-char secret hash to the same 32 bytes.
    expect(createHash('sha256').update('short', 'utf8').digest().length).toBe(32)
    expect(createHash('sha256').update('x'.repeat(500), 'utf8').digest().length).toBe(32)
  })
})

describe('the preview route uses it', () => {
  it('the route exists and still gates draft mode', async () => {
    const src = await fs.readFile(ROUTE, 'utf8')
    expect(src.length).toBeGreaterThan(400) // the read is real
    // The subject must still be PRESENT and still do its job — deleting the
    // route must not make this file pass.
    expect(src).toContain('draftMode')
    expect(src).toContain('dm.enable()')
    expect(src).toContain('BARKPARK_PREVIEW_SECRET')
    expect(src).toContain('401')
    // The fail-closed-in-production arm survives untouched.
    expect(src).toContain("process.env.NODE_ENV === 'production'")
  })

  it('compares the secret in constant time, not with !==', async () => {
    const src = await fs.readFile(ROUTE, 'utf8')
    expect(src).toContain('constantTimeEqual')
    // The exact shipped defect line.
    expect(src).not.toContain("url.searchParams.get('secret') !== secret")
    // And the class of it: no raw !== / === against the secret variable.
    expect(/[!=]==\s*secret\b/.test(src)).toBe(false)
    expect(/\bsecret\s*[!=]==/.test(src)).toBe(false)
  })

  it('pins the Node runtime that node:crypto needs', async () => {
    const src = await fs.readFile(ROUTE, 'utf8')
    expect(src).toContain("export const runtime = 'nodejs'")
  })

  it('keeps the same-origin redirect guard it already had', async () => {
    // Do not churn what was already sound: the open-redirect rejection stays.
    const src = await fs.readFile(ROUTE, 'utf8')
    expect(src).toContain("raw.startsWith('/')")
    expect(src).toContain("!raw.startsWith('//')")
    expect(src).toContain("!raw.startsWith('/\\\\')")
  })
})
