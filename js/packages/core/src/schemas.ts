// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Schema introspection — the server serializes schemas `for_sdk`:
//   GET /v1/schemas/:dataset        → { schemas: [...], datasetSchemaHash }
//   GET /v1/schemas/:dataset/:name  → { schema: {...} }
// Useful for dynamic/generic UIs that render fields from the schema.

import { scopePrefix } from './scope'
import { request } from './transport'
import { BarkparkNotFoundError } from './errors'
import type { BarkparkClientConfig, BarkparkSchema } from './types'

export async function listSchemas(config: BarkparkClientConfig): Promise<BarkparkSchema[]> {
  const path = `${scopePrefix(config)}/v1/schemas/${encodeURIComponent(config.dataset)}`
  const { data } = await request<{ schemas?: BarkparkSchema[] }>(config, path, { kind: 'read' })
  return data.schemas ?? []
}

export async function getSchema(
  config: BarkparkClientConfig,
  name: string,
): Promise<BarkparkSchema | null> {
  const path = `${scopePrefix(config)}/v1/schemas/${encodeURIComponent(config.dataset)}/${encodeURIComponent(name)}`
  try {
    const { data } = await request<{ schema?: BarkparkSchema }>(config, path, { kind: 'read' })
    return data.schema ?? null
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return null
    throw err
  }
}
