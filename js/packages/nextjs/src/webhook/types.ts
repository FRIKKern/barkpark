// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { WebhookEvent } from '@barkpark/core'

/**
 * Verified webhook payload — `@barkpark/core`'s typed `WebhookEvent` (so the wire
 * contract has ONE source of truth, no drift), plus the handler-specific optional
 * `deliveryId` it reads from the body as a dedup fallback when the
 * `x-barkpark-delivery-id` header is absent (the dispatcher itself sends the id in
 * the header, not the body). `event` / `type` / `doc_id` / `sync_tags` / … are
 * typed; `document` is `Record<string, unknown> | null` — cast it if you need it.
 */
export type WebhookPayload = WebhookEvent & { deliveryId?: string }

/** Config for createWebhookHandler. */
export interface WebhookConfig {
  /** Current HMAC-SHA256 secret. Required. */
  secret: string
  /**
   * Previous HMAC secret. When set, signatures valid under EITHER `secret` or
   * `previousSecret` are accepted. Lets operators rotate without downtime.
   */
  previousSecret?: string
  /**
   * Invoked once HMAC, freshness, and dedup checks pass. Errors surface as 500.
   */
  onMutation: (payload: WebhookPayload) => void | Promise<void>
  /**
   * Freshness tolerance in seconds. Default 300 (5 minutes).
   */
  toleranceSeconds?: number
}

/** Shape returned by createWebhookHandler — mount at an App Router route file. */
export interface WebhookHandlers {
  POST: (req: Request) => Promise<Response>
  GET: (req: Request) => Promise<Response>
}
