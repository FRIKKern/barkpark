import { createHash, timingSafeEqual } from 'node:crypto'

/**
 * Constant-time string comparison for shared secrets.
 *
 * WHY NOT `a !== b`
 *
 * `!==` on strings compares LENGTH first and then bytes with an early exit, so
 * both the length of the expected secret and the position of the first wrong
 * byte are observable in how long the comparison takes. This is the house
 * standard everywhere else in Barkpark that compares a secret —
 * `@barkpark/nextjs`'s `createDraftModeRoutes` (draft-mode/index.ts) and
 * `@barkpark/core`'s webhook verifier both use `timingSafeEqual` — and the
 * preview route is a template, COPIED into every generated project, some of
 * which will run on a long-lived server on a low-jitter network rather than
 * behind a serverless edge.
 *
 * WHY BOTH SIDES ARE HASHED FIRST
 *
 * `crypto.timingSafeEqual` THROWS `RangeError` when the two buffers differ in
 * length, so it cannot be handed raw user input directly. Hashing both sides to
 * a fixed 32-byte SHA-256 digest makes every comparison the same width — which
 * both makes the call safe and removes the length side-channel that an
 * `a.length !== b.length` pre-check would reintroduce.
 *
 * Node runtime only (`node:crypto`); the route that uses this declares
 * `export const runtime = 'nodejs'`.
 *
 * Kept dependency-free (no 'server-only', no next/*, no @barkpark/* imports) so
 * it is unit-testable directly — see create-barkpark-app's
 * tests/template-preview-secret.test.ts, which imports THIS file.
 */
export function constantTimeEqual(a: string | null | undefined, b: string | null | undefined): boolean {
  // A missing or empty secret is never equal to anything — fail closed BEFORE
  // hashing, so an unset env var can't be matched by an empty query param.
  if (typeof a !== 'string' || typeof b !== 'string' || a.length === 0 || b.length === 0) {
    return false
  }
  const ha = createHash('sha256').update(a, 'utf8').digest()
  const hb = createHash('sha256').update(b, 'utf8').digest()
  return timingSafeEqual(ha, hb)
}
