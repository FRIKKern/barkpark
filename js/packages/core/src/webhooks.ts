// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Webhook MANAGEMENT — admin CRUD over `/v1/webhooks/:dataset` (register, list,
// update, delete the webhooks a dataset dispatches). This is the OUTBOUND
// control plane; it is distinct from `webhook.ts`, which verifies the signature
// of an INCOMING delivery. Kept in a separate module so `verifyWebhookSignature`
// stays dependency-free (no transport) and tree-shakeable on the receive side.

import { scopePrefix } from './scope'
import { request } from './transport'
import { BarkparkNotFoundError } from './errors'
import type {
  BarkparkClientConfig,
  Webhook,
  CreateWebhookInput,
  UpdateWebhookInput,
} from './types'

function base(config: BarkparkClientConfig): string {
  return `${scopePrefix(config)}/v1/webhooks/${encodeURIComponent(config.dataset)}`
}

/**
 * List the dataset's registered webhooks (`GET /v1/webhooks/:dataset`).
 * Prefer `client.listWebhooks()`.
 */
export async function listWebhooks(config: BarkparkClientConfig): Promise<Webhook[]> {
  const { data } = await request<{ webhooks?: Webhook[] }>(config, base(config), { kind: 'read' })
  return data.webhooks ?? []
}

/**
 * Fetch one webhook by id (`GET /v1/webhooks/:dataset/:id`), or `null` on 404.
 * Prefer `client.getWebhook()`.
 */
export async function getWebhook(
  config: BarkparkClientConfig,
  id: string,
): Promise<Webhook | null> {
  const path = `${base(config)}/${encodeURIComponent(id)}`
  try {
    const { data } = await request<{ webhook?: Webhook }>(config, path, { kind: 'read' })
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
): Promise<Webhook> {
  const { data } = await request<{ webhook: Webhook }>(config, base(config), {
    method: 'POST',
    kind: 'write',
    body: input,
  })
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
): Promise<Webhook> {
  const path = `${base(config)}/${encodeURIComponent(id)}`
  const { data } = await request<{ webhook: Webhook }>(config, path, {
    method: 'PUT',
    kind: 'write',
    body: input,
  })
  return data.webhook
}

/**
 * Delete a webhook by id (`DELETE /v1/webhooks/:dataset/:id`). Returns
 * `{ deleted: id }`. Prefer `client.deleteWebhook()`.
 */
export async function deleteWebhook(
  config: BarkparkClientConfig,
  id: string,
): Promise<{ deleted: string }> {
  const path = `${base(config)}/${encodeURIComponent(id)}`
  const { data } = await request<{ deleted: string }>(config, path, {
    method: 'DELETE',
    kind: 'write',
  })
  return data
}
