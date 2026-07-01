// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Dataset analytics — a content-stats overview (`GET /v1/data/analytics/:dataset`):
// total document count, per-type published/draft counts, and recent activity.
// A token-required scoped read (same tier as export / history / revision).

import { scopePrefix } from './scope'
import { request } from './transport'
import type { BarkparkClientConfig, DatasetAnalytics } from './types'

/**
 * Fetch the dataset's content-stats overview
 * (`GET /v1/data/analytics/:dataset`): total documents, per-type counts
 * (published vs draft), and recent activity. Prefer `client.getAnalytics()`.
 */
export async function getAnalytics(
  config: BarkparkClientConfig,
  opts?: { signal?: AbortSignal },
): Promise<DatasetAnalytics> {
  const path = `${scopePrefix(config)}/v1/data/analytics/${encodeURIComponent(config.dataset)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<DatasetAnalytics>(config, path, reqOpts)
  return data
}
