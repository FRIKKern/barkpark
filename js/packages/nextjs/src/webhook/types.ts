// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * Verified webhook payload shape. The handler does not enforce a strict shape on
 * mutation events — only that the body is valid JSON. Consumers may narrow.
 */
export type WebhookPayload = Record<string, unknown>

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
