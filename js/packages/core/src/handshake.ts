// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClientConfig, MetaResponse } from './types'
import { request } from './transport'

export interface HandshakeCache {
  /** Fetch + cache /v1/meta. Dedupes concurrent calls by projectUrl+dataset. */
  get(config: BarkparkClientConfig): Promise<MetaResponse>
  /** Invalidate cache entry (used on SchemaMismatch). */
  invalidate(config: BarkparkClientConfig): void
  /** Clear entire cache (used in tests). */
  clear(): void
}

interface CacheEntry {
  resolved?: MetaResponse
  inflight?: Promise<MetaResponse>
}

function cacheKey(config: BarkparkClientConfig): string {
  return `${config.projectUrl}|${config.dataset}`
}

/**
 * Build a lazy `/v1/meta` handshake cache, keyed by `projectUrl + dataset`.
 *
 * Dedupes concurrent `get()` calls (multiple callers share one inflight promise),
 * caches the resolved {@link MetaResponse}, and drops the entry on reject so the
 * next caller retries. Exposed for tests and advanced drift-detection flows —
 * normal apps should use `client.handshake()` (which owns a per-instance cache).
 *
 * @see ADR-007 §Handshake caching.
 */
export function createHandshakeCache(): HandshakeCache {
  const map = new Map<string, CacheEntry>()

  return {
    get(config) {
      const key = cacheKey(config)
      const entry = map.get(key)
      if (entry?.resolved) return Promise.resolve(entry.resolved)
      if (entry?.inflight) return entry.inflight

      const inflight = (async () => {
        const { data } = await request<MetaResponse>(config, `/v1/meta?dataset=${encodeURIComponent(config.dataset)}`, {
          method: 'GET',
          kind: 'read',
        })
        return data
      })()

      const newEntry: CacheEntry = { inflight }
      map.set(key, newEntry)

      inflight.then(
        (value) => {
          map.set(key, { resolved: value })
        },
        () => {
          // Clear entry on failure so next caller retries.
          map.delete(key)
        },
      )

      return inflight
    },
    invalidate(config) {
      map.delete(cacheKey(config))
    },
    clear() {
      map.clear()
    },
  }
}
