// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Runtime-agnostic webhook signature verification. Uses Web Crypto
// (`crypto.subtle`) — available in Node 18+, browsers, edge runtimes, and
// workers — so it has no `node:crypto` dependency and works anywhere the rest of
// the SDK does (unlike @barkpark/nextjs's handler, which is Node-only). Mirrors
// the dispatcher's `x-barkpark-signature: t=<unix>,v1=<hex>` header, where the
// signed material is `"<t>.<body>"` (HMAC-SHA256), and enforces a freshness
// window so a captured delivery can't be replayed.

/** Options for {@link verifyWebhookSignature}. */
export interface VerifyWebhookOptions {
  /** The raw request body string, exactly as received — do NOT re-serialize. */
  body: string
  /** The `x-barkpark-signature` header value (`t=<unix>,v1=<hex>`). */
  signature: string | null | undefined
  /** The webhook's signing secret. */
  secret: string
  /** A rotated-out secret to also accept during a secret rotation window. */
  previousSecret?: string
  /** Max age of the signed timestamp in seconds (default 300 = ±5 min). */
  toleranceSeconds?: number
  /** Override "now" (unix seconds) — for deterministic testing. */
  nowSeconds?: number
}

interface ParsedSignature {
  t: number
  v1: string
}

/** Parse the `t=<unix>,v1=<hex>` signature header; null if either part is absent. */
function parseSignature(raw: string | null | undefined): ParsedSignature | null {
  if (typeof raw !== 'string' || raw.length === 0) return null
  let t: number | null = null
  let v1: string | null = null
  for (const part of raw.split(',')) {
    const p = part.trim()
    if (p.startsWith('t=')) {
      const n = Number(p.slice(2))
      if (Number.isFinite(n)) t = n
    } else if (p.startsWith('v1=')) {
      v1 = p.slice(3)
    }
  }
  if (t === null || v1 === null || v1.length === 0) return null
  return { t, v1 }
}

/** Lowercase-hex HMAC-SHA256 of `message` under `secret`, via Web Crypto. */
async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(message))
  let hex = ''
  for (const b of new Uint8Array(mac)) hex += b.toString(16).padStart(2, '0')
  return hex
}

/**
 * Constant-time compare of two hex strings. The length check can leak only the
 * EXPECTED length (a public constant — 64 for SHA-256), never the secret.
 */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

/**
 * Verify a Barkpark webhook signature in any runtime. Returns `true` only when
 * the HMAC matches `secret` (or `previousSecret`) AND the signed timestamp is
 * within `toleranceSeconds` of now (replay defense). Never throws on a bad or
 * malformed signature — it returns `false`.
 *
 * @example
 * const ok = await verifyWebhookSignature({
 *   body: await req.text(),
 *   signature: req.headers.get('x-barkpark-signature'),
 *   secret: process.env.BARKPARK_WEBHOOK_SECRET!,
 * })
 * if (!ok) return new Response('bad signature', { status: 401 })
 */
export async function verifyWebhookSignature(opts: VerifyWebhookOptions): Promise<boolean> {
  const parsed = parseSignature(opts.signature)
  if (parsed === null) return false

  const tolerance = opts.toleranceSeconds ?? 300
  const now = opts.nowSeconds ?? Math.floor(Date.now() / 1000)
  if (Math.abs(now - parsed.t) > tolerance) return false

  const signed = `${parsed.t}.${opts.body}`
  const expected = await hmacSha256Hex(opts.secret, signed)
  if (timingSafeEqual(expected, parsed.v1)) return true

  if (typeof opts.previousSecret === 'string' && opts.previousSecret.length > 0) {
    const expectedPrev = await hmacSha256Hex(opts.previousSecret, signed)
    if (timingSafeEqual(expectedPrev, parsed.v1)) return true
  }
  return false
}

/**
 * The mutation that fired a webhook — the server's present-tense verbs
 * (`@valid_events`), matching {@link ListenEvent.mutation}. The `(string & {})`
 * arm keeps autocomplete on the known kinds while staying forward-compatible
 * with any verb a newer server adds.
 */
export type WebhookEventKind =
  | 'create'
  | 'update'
  | 'delete'
  | 'publish'
  | 'unpublish'
  | 'discardDraft'
  | 'patch'
  | (string & {})

/**
 * The JSON body Barkpark POSTs to a webhook subscriber. Field names mirror the
 * dispatcher's wire shape (snake_case). Verify the signature with
 * {@link verifyWebhookSignature} first, then parse with {@link parseWebhookEvent}.
 *
 * @typeParam TDocument — type of the affected `document` (e.g. a generated `Post`).
 */
export interface WebhookEvent<TDocument = Record<string, unknown>> {
  /** What happened — one of `'create'` | `'update'` | `'delete'` | `'publish'` | `'unpublish'` | `'discardDraft'` | `'patch'`. */
  event: WebhookEventKind
  /** The affected document's type. */
  type: string
  /** The affected document's id. */
  doc_id: string
  /** The affected document (`null` when not applicable, e.g. some deletes). */
  document: TDocument | null
  dataset: string
  /** Workspace slug, or `null` when unscoped. */
  workspace: string | null
  /** Project slug, or `null` when unscoped. */
  project: string | null
  workspace_id: string | null
  project_id: string | null
  /** Cache-revalidation tags for this event (scoped + legacy dataset-only). */
  sync_tags: string[]
  /** ISO-8601 dispatch timestamp. */
  timestamp: string
}

/**
 * Parse a webhook body into a typed {@link WebhookEvent} — a thin, typed wrapper
 * over `JSON.parse`. ALWAYS {@link verifyWebhookSignature} first; parsing an
 * unverified body trusts the sender.
 */
export function parseWebhookEvent<TDocument = Record<string, unknown>>(
  body: string,
): WebhookEvent<TDocument> {
  return JSON.parse(body) as WebhookEvent<TDocument>
}
