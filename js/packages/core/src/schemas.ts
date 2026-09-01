// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Schema introspection — the server serializes schemas `for_sdk`:
//   GET /v1/schemas/:dataset        → { schemas: [...], datasetSchemaHash }
//   GET /v1/schemas/:dataset/:name  → { schema: {...} }
// Useful for dynamic/generic UIs that render fields from the schema.

import { scopePrefix } from './scope'
import { assertSegment } from './util/guards'
import { request } from './transport'
import { BarkparkNotFoundError, BarkparkValidationError } from './errors'
import type { BarkparkClientConfig, BarkparkSchema, UpsertSchemaInput } from './types'

export async function listSchemas(
  config: BarkparkClientConfig,
  opts?: { signal?: AbortSignal },
): Promise<BarkparkSchema[]> {
  const path = `${scopePrefix(config)}/v1/schemas/${encodeURIComponent(config.dataset)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ schemas?: BarkparkSchema[] }>(config, path, reqOpts)
  return data.schemas ?? []
}

export async function getSchema(
  config: BarkparkClientConfig,
  name: string,
  opts?: { signal?: AbortSignal },
): Promise<BarkparkSchema | null> {
  assertSegment(name, 'name', 'getSchema: schema name is required (one path segment)')
  const path = `${scopePrefix(config)}/v1/schemas/${encodeURIComponent(config.dataset)}/${encodeURIComponent(name)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  try {
    const { data } = await request<{ schema?: BarkparkSchema }>(config, path, reqOpts)
    return data.schema ?? null
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return null
    throw err
  }
}

/**
 * Register (create or replace) a content-type schema
 * (`POST /v1/schemas/:dataset`). Idempotent upsert — posting an existing `name`
 * replaces it. Throws `BarkparkValidationError` if the definition is invalid.
 * Returns the server's echoed schema. Prefer `client.upsertSchema()`.
 */
export async function upsertSchema(
  config: BarkparkClientConfig,
  schema: UpsertSchemaInput,
): Promise<BarkparkSchema> {
  if (typeof schema?.name !== 'string' || !schema.name.trim())
    throw new BarkparkValidationError('upsertSchema: schema name is required', { field: 'name' })
  if (!Array.isArray(schema?.fields))
    throw new BarkparkValidationError('upsertSchema: schema fields must be an array', { field: 'fields' })
  for (const entry of schema.fields) {
    if (
      typeof entry !== 'object' ||
      entry === null ||
      typeof entry.name !== 'string' ||
      !entry.name.trim() ||
      typeof entry.type !== 'string' ||
      !entry.type.trim()
    )
      throw new BarkparkValidationError(
        'upsertSchema: each field requires a non-empty string name and type',
        { field: 'fields' },
      )
  }
  const path = `${scopePrefix(config)}/v1/schemas/${encodeURIComponent(config.dataset)}`
  const { data } = await request<BarkparkSchema>(config, path, {
    method: 'POST',
    kind: 'write',
    body: schema,
  })
  return data
}

/**
 * Delete a content-type schema by name (`DELETE /v1/schemas/:dataset/:name`).
 * Returns `{ deleted: name }`. Prefer `client.deleteSchema()`.
 */
export async function deleteSchema(
  config: BarkparkClientConfig,
  name: string,
): Promise<{ deleted: string }> {
  assertSegment(name, 'name', 'deleteSchema: schema name is required (one path segment)')
  const path = `${scopePrefix(config)}/v1/schemas/${encodeURIComponent(config.dataset)}/${encodeURIComponent(name)}`
  const { data } = await request<{ deleted: string }>(config, path, {
    method: 'DELETE',
    kind: 'write',
  })
  return data
}
