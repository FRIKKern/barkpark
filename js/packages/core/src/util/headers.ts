// src/util/headers.ts
// Pure helpers. Zero side effects on import. No node:* imports.

export const BARKPARK_VENDOR_ACCEPT = 'application/vnd.barkpark+json'

/**
 * Build the default headers every Barkpark request carries.
 * Caller merges additional headers (Authorization, Idempotency-Key, If-Match).
 */
export function buildBaseHeaders(extra?: Record<string, string>): Record<string, string> {
  return {
    Accept: BARKPARK_VENDOR_ACCEPT,
    'Content-Type': 'application/json',
    ...(extra ?? {}),
  }
}

/**
 * Generate a UUIDv7 (time-ordered UUID) suitable for Idempotency-Key.
 * Per RFC 9562 §5.7: 48-bit big-endian unix_ts_ms, 4-bit version (7), 12-bit rand_a, 2-bit variant (0b10), 62-bit rand_b.
 *
 * Uses crypto.getRandomValues when available (all target runtimes), falls back to Math.random
 * ONLY for environments where getRandomValues is unavailable (should never happen in Node 20+, bun, workerd, browser).
 *
 * Returns: 'xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx' (36 chars, 5 groups, version 7, variant 10)
 */
export function uuidv7(): string {
  const now = BigInt(Date.now())
  const bytes = new Uint8Array(16)

  // 48-bit timestamp big-endian
  bytes[0] = Number((now >> 40n) & 0xffn)
  bytes[1] = Number((now >> 32n) & 0xffn)
  bytes[2] = Number((now >> 24n) & 0xffn)
  bytes[3] = Number((now >> 16n) & 0xffn)
  bytes[4] = Number((now >> 8n) & 0xffn)
  bytes[5] = Number(now & 0xffn)

  // Fill 6..15 with cryptographic randomness
  const rand = new Uint8Array(10)
  const g = globalThis as any
  if (g?.crypto?.getRandomValues) {
    g.crypto.getRandomValues(rand)
  } else {
    // Last-resort fallback — should not be reached in supported runtimes
    for (let i = 0; i < 10; i++) rand[i] = Math.floor(Math.random() * 256)
  }
  bytes.set(rand, 6)

  // Set version (7) in byte 6, top 4 bits
  bytes[6] = (bytes[6]! & 0x0f) | 0x70
  // Set variant (0b10xxxxxx) in byte 8, top 2 bits
  bytes[8] = (bytes[8]! & 0x3f) | 0x80

  // Format as 8-4-4-4-12 hex
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`
}

/**
 * Phoenix returns `request_id` snake_case in error envelopes; the SDK exposes it as `requestId`.
 * This helper lets transport.ts normalize the error body shape.
 *
 * Returns the first non-empty value of (snake, camel) or undefined.
 */
export function pickRequestId(body: unknown): string | undefined {
  if (!body || typeof body !== 'object') return undefined
  const b = body as Record<string, unknown>
  const snake = b['request_id']
  if (typeof snake === 'string' && snake.length > 0) return snake
  const camel = b['requestId']
  if (typeof camel === 'string' && camel.length > 0) return camel
  return undefined
}
