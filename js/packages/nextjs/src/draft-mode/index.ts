// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import 'server-only'

import { createHmac, timingSafeEqual } from 'node:crypto'
import { draftMode } from 'next/headers'

import type { DraftModeConfig, DraftModeHandlers } from './types'

export type { DraftModeConfig, DraftModeHandlers } from './types'

const DEFAULT_TTL_MS = 10 * 60 * 1000

function computeSignature(path: string, expiry: number, secret: string): string {
  return createHmac('sha256', secret).update(`${path}\n${expiry}`).digest('hex')
}

function constantTimeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length || a.length === 0) return false
  const aBuf = Buffer.from(a, 'hex')
  const bBuf = Buffer.from(b, 'hex')
  if (aBuf.length !== bBuf.length || aBuf.length === 0) return false
  return timingSafeEqual(aBuf, bBuf)
}

interface VerifyInput {
  path: string | null
  expiry: number | null
  sign: string | null
  secret: string
  now: number
}

type VerifyResult = { ok: true } | { ok: false; reason: 'missing' | 'expired' | 'mismatch' }

function verifySignature(input: VerifyInput): VerifyResult {
  if (input.path === null || input.expiry === null || input.sign === null) {
    return { ok: false, reason: 'missing' }
  }
  if (!Number.isFinite(input.expiry) || input.expiry < input.now) {
    return { ok: false, reason: 'expired' }
  }
  const expected = computeSignature(input.path, input.expiry, input.secret)
  if (!constantTimeEqualHex(expected, input.sign)) {
    return { ok: false, reason: 'mismatch' }
  }
  return { ok: true }
}

/**
 * Build a signed preview URL payload. The CMS (or a trusted admin tool) calls this to
 * produce `{ path, expiry, sign }` then redirects the editor to
 * `/api/draft?path=<path>&expiry=<expiry>&sign=<sign>` — whichever route the consumer
 * mounted the returned GET handler at.
 */
export function signDraftModeToken(opts: {
  path: string
  secret: string
  ttlMs?: number
  now?: number
}): { path: string; expiry: number; sign: string } {
  if (typeof opts.path !== 'string' || opts.path.length === 0) {
    throw new TypeError('signDraftModeToken: path must be a non-empty string')
  }
  if (typeof opts.secret !== 'string' || opts.secret.length === 0) {
    throw new TypeError('signDraftModeToken: secret must be a non-empty string')
  }
  const ttl = opts.ttlMs ?? DEFAULT_TTL_MS
  const expiry = (opts.now ?? Date.now()) + ttl
  return { path: opts.path, expiry, sign: computeSignature(opts.path, expiry, opts.secret) }
}

/**
 * Phase 5 v0.1 — draft-mode route factory (masterplan L167; see ADR-004 via
 * .doey/plans/research/w2-nextjs-contracts.md §5).
 *
 * Signed URL contract (HMAC over `path + '\n' + expiry`, 10-min TTL):
 *   GET    /api/draft?path=<path>&expiry=<unix_ms>&sign=<hex_hmac>
 *          → verify → draftMode().enable() → 307 redirect to resolved path
 *          → on invalid/expired: call reissuePreviewToken?.() once, retry verify
 *          → second failure: 401
 *   DELETE /api/draft
 *          → draftMode().disable() → 200
 *
 * Server-only (node:crypto + next/headers). No React. No runtime deps beyond Next 15.
 * `draftMode()` is async in Next 15 (next/headers returns a Promise).
 */
export function createDraftModeRoutes(cfg: DraftModeConfig): DraftModeHandlers {
  validateConfig(cfg)

  const GET = async (req: Request): Promise<Response> => {
    const url = new URL(req.url)
    const path = url.searchParams.get('path')
    const sign = url.searchParams.get('sign')
    const expiryRaw = url.searchParams.get('expiry')
    const expiry = expiryRaw === null ? null : Number(expiryRaw)
    const now = Date.now()

    let result = verifySignature({ path, expiry, sign, secret: cfg.previewSecret, now })
    if (!result.ok && cfg.reissuePreviewToken !== undefined) {
      const altSecret = await cfg.reissuePreviewToken()
      if (typeof altSecret === 'string' && altSecret.length > 0) {
        result = verifySignature({ path, expiry, sign, secret: altSecret, now })
      }
    }

    if (!result.ok) {
      return new Response(`draft-mode: ${result.reason}`, {
        status: 401,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      })
    }

    const dm = await draftMode()
    dm.enable()

    const verifiedPath = path as string
    const target = cfg.resolvePath !== undefined ? cfg.resolvePath(verifiedPath) : verifiedPath
    return new Response(null, { status: 307, headers: { Location: target } })
  }

  const DELETE = async (_req: Request): Promise<Response> => {
    const dm = await draftMode()
    dm.disable()
    return new Response(null, { status: 200 })
  }

  return { GET, DELETE }
}

function validateConfig(cfg: DraftModeConfig): void {
  if (cfg === null || typeof cfg !== 'object') {
    throw new TypeError('createDraftModeRoutes: config must be an object')
  }
  if (typeof cfg.previewSecret !== 'string' || cfg.previewSecret.length === 0) {
    throw new TypeError('createDraftModeRoutes: previewSecret must be a non-empty string')
  }
  if (cfg.resolvePath !== undefined && typeof cfg.resolvePath !== 'function') {
    throw new TypeError('createDraftModeRoutes: resolvePath must be a function')
  }
  if (cfg.reissuePreviewToken !== undefined && typeof cfg.reissuePreviewToken !== 'function') {
    throw new TypeError('createDraftModeRoutes: reissuePreviewToken must be a function')
  }
}
