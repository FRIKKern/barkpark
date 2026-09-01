// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Webhook MANAGEMENT — admin CRUD over `/v1/webhooks/:dataset` (register, list,
// update, delete the webhooks a dataset dispatches). This is the OUTBOUND
// control plane; it is distinct from `webhook.ts`, which verifies the signature
// of an INCOMING delivery. Kept in a separate module so `verifyWebhookSignature`
// stays dependency-free (no transport) and tree-shakeable on the receive side.

import { scopePrefix } from './scope'
import { assertSegment, isHttpUrl } from './util/guards'
import { request } from './transport'
import { BarkparkNotFoundError, BarkparkValidationError } from './errors'
import type {
  BarkparkClientConfig,
  Webhook,
  CreateWebhookInput,
  UpdateWebhookInput,
} from './types'

function base(config: BarkparkClientConfig): string {
  return `${scopePrefix(config)}/v1/webhooks/${encodeURIComponent(config.dataset)}`
}

// Reject a scheme-less/typo'd delivery URL client-side — a bad url ships to the
// server otherwise and the hook silently never fires. Mirrors the absolute
// http(s) guard in client.ts validateConfig for projectUrl. The parse+allowlist
// itself lives in util/guards.ts (`isHttpUrl`), shared with imageUrl so the
// package has exactly ONE scheme allowlist.
function assertWebhookUrl(url: string, fn: string): void {
  if (!isHttpUrl(url)) {
    throw new BarkparkValidationError(`${fn}: url must be an absolute http(s) URL`, { field: 'url' })
  }
}

/**
 * List the dataset's registered webhooks (`GET /v1/webhooks/:dataset`).
 * Prefer `client.listWebhooks()`.
 */
export async function listWebhooks(
  config: BarkparkClientConfig,
  opts?: { signal?: AbortSignal },
): Promise<Webhook[]> {
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ webhooks?: Webhook[] }>(config, base(config), reqOpts)
  return data.webhooks ?? []
}

/**
 * Fetch one webhook by id (`GET /v1/webhooks/:dataset/:id`), or `null` on 404.
 * Prefer `client.getWebhook()`.
 */
export async function getWebhook(
  config: BarkparkClientConfig,
  id: string,
  opts?: { signal?: AbortSignal },
): Promise<Webhook | null> {
  assertSegment(id, 'id')
  const path = `${base(config)}/${encodeURIComponent(id)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  try {
    const { data } = await request<{ webhook?: Webhook }>(config, path, reqOpts)
    return data.webhook ?? null
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return null
    throw err
  }
}

/**
 * Register a webhook (`POST /v1/webhooks/:dataset`). `name` + `url` are required;
 * `events`/`types` scope which deliveries fire, `secret` signs them. Returns the
 * created webhook (the `secret` is never echoed back). Prefer `client.createWebhook()`.
 */
export async function createWebhook(
  config: BarkparkClientConfig,
  input: CreateWebhookInput,
  opts?: { signal?: AbortSignal },
): Promise<Webhook> {
  if (typeof input?.name !== 'string' || !input.name) {
    throw new BarkparkValidationError('createWebhook: name is required', { field: 'name' })
  }
  if (typeof input?.url !== 'string' || !input.url) {
    throw new BarkparkValidationError('createWebhook: url is required', { field: 'url' })
  }
  assertWebhookUrl(input.url, 'createWebhook')
  const reqOpts: { kind: 'write'; method: 'POST'; body: unknown; signal?: AbortSignal } = {
    kind: 'write',
    method: 'POST',
    body: input,
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ webhook: Webhook }>(config, base(config), reqOpts)
  return data.webhook
}

/**
 * Update a webhook (`PUT /v1/webhooks/:dataset/:id`). Returns the updated webhook.
 * Prefer `client.updateWebhook()`.
 */
export async function updateWebhook(
  config: BarkparkClientConfig,
  id: string,
  input: UpdateWebhookInput,
  opts?: { signal?: AbortSignal },
): Promise<Webhook> {
  assertSegment(id, 'id')
  // Partial patch — only validate url when the caller is actually changing it.
  if (input.url !== undefined) assertWebhookUrl(input.url, 'updateWebhook')
  const path = `${base(config)}/${encodeURIComponent(id)}`
  const reqOpts: { kind: 'write'; method: 'PUT'; body: unknown; signal?: AbortSignal } = {
    kind: 'write',
    method: 'PUT',
    body: input,
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ webhook: Webhook }>(config, path, reqOpts)
  return data.webhook
}

/**
 * Delete a webhook by id (`DELETE /v1/webhooks/:dataset/:id`). Returns
 * `{ deleted: id }`. Prefer `client.deleteWebhook()`.
 */
export async function deleteWebhook(
  config: BarkparkClientConfig,
  id: string,
  opts?: { signal?: AbortSignal },
): Promise<{ deleted: string }> {
  assertSegment(id, 'id')
  const path = `${base(config)}/${encodeURIComponent(id)}`
  const reqOpts: { kind: 'write'; method: 'DELETE'; signal?: AbortSignal } = {
    kind: 'write',
    method: 'DELETE',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ deleted: string }>(config, path, reqOpts)
  return data
}
