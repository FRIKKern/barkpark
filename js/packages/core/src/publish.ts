// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClientConfig, MutateEnvelope, MutateResult } from './types'
import { request } from './transport'
import { BarkparkValidationError } from './errors'

/**
 * Publish a draft document.
 *
 * Copies `drafts.{id}` → `{id}` and deletes the draft in one Phoenix transaction.
 * Returns the resulting {@link MutateResult} with `operation: 'publish'`.
 * Prefer `client.publish(id, type)`.
 */
export async function publishDoc(
  config: BarkparkClientConfig,
  id: string,
  type: string,
): Promise<MutateResult> {
  if (!id || !type) {
    throw new BarkparkValidationError('publishDoc requires id and type', {
      field: !id ? 'id' : 'type',
    })
  }
  const { data } = await request<MutateEnvelope>(
    config,
    `/v1/data/mutate/${config.dataset}`,
    {
      method: 'POST',
      body: { mutations: [{ publish: { id, type } }] },
      kind: 'write',
    },
  )
  const first = data.results[0]
  if (!first) {
    throw new BarkparkValidationError('publish: server returned empty results', {
      field: 'results',
    })
  }
  return first
}

/**
 * Unpublish (move back to draft) a published document.
 *
 * Moves `{id}` → `drafts.{id}`. Returns the resulting {@link MutateResult}
 * with `operation: 'unpublish'`. Prefer `client.unpublish(id, type)`.
 */
export async function unpublishDoc(
  config: BarkparkClientConfig,
  id: string,
  type: string,
): Promise<MutateResult> {
  if (!id || !type) {
    throw new BarkparkValidationError('unpublishDoc requires id and type', {
      field: !id ? 'id' : 'type',
    })
  }
  const { data } = await request<MutateEnvelope>(
    config,
    `/v1/data/mutate/${config.dataset}`,
    {
      method: 'POST',
      body: { mutations: [{ unpublish: { id, type } }] },
      kind: 'write',
    },
  )
  const first = data.results[0]
  if (!first) {
    throw new BarkparkValidationError('unpublish: server returned empty results', {
      field: 'results',
    })
  }
  return first
}
