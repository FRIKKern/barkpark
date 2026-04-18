// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import 'server-only'

import { createHmac, timingSafeEqual } from 'node:crypto'

import type { WebhookConfig, WebhookHandlers, WebhookPayload } from './types'

export type { WebhookConfig, WebhookHandlers, WebhookPayload } from './types'

const SIG_HEADER = 'x-barkpark-signature'
const DELIVERY_HEADER = 'x-barkpark-delivery-id'
const DEFAULT_TOLERANCE_S = 300
const DEDUP_LRU_SIZE = 512

// Module-scoped delivery-id LRU. ~512 keys ≈ a few KB; fine for serverless
// instance memory. P1-k duplicates are also dropped server-side by Phoenix; this
// is belt-and-suspenders for at-least-once retry storms hitting one warm instance.
const seenDeliveries = new Set<string>()

function rememberDelivery(id: string): boolean {
  if (seenDeliveries.has(id)) return true
  seenDeliveries.add(id)
  if (seenDeliveries.size > DEDUP_LRU_SIZE) {
    const oldest = seenDeliveries.values().next().value
    if (oldest !== undefined) seenDeliveries.delete(oldest)
  }
  return false
}

function parseSignatureHeader(raw: string | null): { t: number; v1: string } | null {
  if (raw === null) return null
  let t: number | null = null
  let v1: string | null = null
  for (const part of raw.split(',')) {
    const trimmed = part.trim()
    if (trimmed.startsWith('t=')) {
      const n = Number(trimmed.slice(2))
      if (!Number.isFinite(n) || n <= 0) return null
      t = Math.floor(n)
    } else if (trimmed.startsWith('v1=')) {
      const hex = trimmed.slice(3)
      if (hex.length === 0 || !/^[0-9a-f]+$/i.test(hex)) return null
      v1 = hex.toLowerCase()
    }
  }
  if (t === null || v1 === null) return null
  return { t, v1 }
}

function computeHmacHex(secret: string, signedPayload: string): string {
  return createHmac('sha256', secret).update(signedPayload).digest('hex')
}

function constantTimeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length || a.length === 0) return false
  const aBuf = Buffer.from(a, 'hex')
  const bBuf = Buffer.from(b, 'hex')
  if (aBuf.length !== bBuf.length || aBuf.length === 0) return false
  return timingSafeEqual(aBuf, bBuf)
}

function verifyUnderSecret(secret: string | undefined, signedPayload: string, provided: string): boolean {
  if (secret === undefined || secret.length === 0) return false
  return constantTimeEqualHex(computeHmacHex(secret, signedPayload), provided)
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  })
}

function validateConfig(cfg: WebhookConfig): void {
  if (cfg === null || typeof cfg !== 'object') {
    throw new TypeError('createWebhookHandler: config must be an object')
  }
  if (typeof cfg.secret !== 'string' || cfg.secret.length === 0) {
    throw new TypeError('createWebhookHandler: secret must be a non-empty string')
  }
  if (cfg.previousSecret !== undefined &&
    (typeof cfg.previousSecret !== 'string' || cfg.previousSecret.length === 0)) {
    throw new TypeError('createWebhookHandler: previousSecret must be a non-empty string when set')
  }
  if (typeof cfg.onMutation !== 'function') {
    throw new TypeError('createWebhookHandler: onMutation must be a function')
  }
  if (cfg.toleranceSeconds !== undefined &&
    (typeof cfg.toleranceSeconds !== 'number' || cfg.toleranceSeconds <= 0)) {
    throw new TypeError('createWebhookHandler: toleranceSeconds must be a positive number')
  }
}

/**
 * Creates an App Router-compatible webhook handler.
 *
 * Contract:
 *   POST /your/route
 *     Header  x-barkpark-signature: t=<unix>,v1=<hex>      (HMAC-SHA256 of `t.body`)
 *     Header  x-barkpark-delivery-id: <id>                 (optional; falls back to body.deliveryId)
 *     Body    application/json
 *   Responses (JSON)
 *     200 { ok: true }                onMutation succeeded
 *     200 { deduped: true }           delivery id seen recently
 *     401 { error: 'bad_signature' }  missing/invalid HMAC
 *     401 { error: 'stale' }          timestamp ±5min outside server clock
 *     400 { error: 'bad_request' }    body unreadable / non-JSON
 *     500 { error: 'handler_failed' } onMutation threw
 *
 *   GET → 405 { error: 'method_not_allowed' }
 */
export function createWebhookHandler(cfg: WebhookConfig): WebhookHandlers {
  validateConfig(cfg)
  const toleranceSeconds =
    typeof cfg.toleranceSeconds === 'number' && cfg.toleranceSeconds > 0
      ? Math.floor(cfg.toleranceSeconds)
      : DEFAULT_TOLERANCE_S

  const POST = async (req: Request): Promise<Response> => {
    const parsedSig = parseSignatureHeader(req.headers.get(SIG_HEADER))
    if (parsedSig === null) return json(401, { error: 'bad_signature' })

    const nowSec = Math.floor(Date.now() / 1000)
    if (Math.abs(nowSec - parsedSig.t) > toleranceSeconds) {
      return json(401, { error: 'stale' })
    }

    let rawBody: string
    try {
      rawBody = await req.text()
    } catch {
      return json(400, { error: 'bad_request' })
    }

    const signedPayload = `${parsedSig.t}.${rawBody}`
    const ok =
      verifyUnderSecret(cfg.secret, signedPayload, parsedSig.v1) ||
      verifyUnderSecret(cfg.previousSecret, signedPayload, parsedSig.v1)
    if (!ok) return json(401, { error: 'bad_signature' })

    let payload: WebhookPayload
    try {
      const parsed = rawBody.length === 0 ? {} : JSON.parse(rawBody)
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return json(400, { error: 'bad_request' })
      }
      payload = parsed as WebhookPayload
    } catch {
      return json(400, { error: 'bad_request' })
    }

    const deliveryId =
      req.headers.get(DELIVERY_HEADER) ??
      (typeof payload.deliveryId === 'string' && payload.deliveryId.length > 0
        ? payload.deliveryId
        : null)

    if (deliveryId !== null && rememberDelivery(deliveryId)) {
      return json(200, { deduped: true })
    }

    try {
      await cfg.onMutation(payload)
    } catch {
      return json(500, { error: 'handler_failed' })
    }

    return json(200, { ok: true })
  }

  const GET = async (_req: Request): Promise<Response> =>
    json(405, { error: 'method_not_allowed' })

  return { POST, GET }
}

/** Test-only: clear the dedup LRU between cases. Not part of the public surface. */
export function __resetDedupForTests(): void {
  seenDeliveries.clear()
}
