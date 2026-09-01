// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClientConfig, MetaResponse } from './types'
import { request } from './transport'
import { scopePrefix } from './scope'

/**
 * @internal A cache-management surface whose two useful methods are lifecycle
 * details this package owns: `invalidate` is called for the consumer on a
 * schema mismatch, and `clear` exists for tests. `createHandshakeCache` is
 * exported and returns one, so a consumer who needs their own cache instance
 * can already get it; naming the interface would additionally freeze these
 * three methods as a contract for something whose invalidation rules are
 * expected to follow the server's meta endpoint rather than the caller.
 */
export interface HandshakeCache {
  /** Fetch + cache /v1/meta. Dedupes concurrent calls by projectUrl+workspace+project+dataset. */
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
  // Include workspace + project: the actual /v1/meta request is prefixed with
  // scopePrefix(config), so two configs sharing projectUrl+dataset but differing
  // in scope hit DIFFERENT endpoints (distinct schema hashes) and must NOT
  // collide on one entry — else the second caller gets the first scope's meta,
  // corrupting schema-drift detection.
  return `${config.projectUrl}|${config.workspace ?? ''}|${config.project ?? ''}|${config.dataset}`
}

/**
 * Build a lazy `/v1/meta` handshake cache, keyed by `projectUrl + workspace +
 * project + dataset` (the full scope the request URL is built from).
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
        // scopePrefix() is invoked at request time (not module top-level) so the
        // handshake ↔ client import cycle stays benign. '' when unscoped (back-compat).
        const prefix = scopePrefix(config)
        const { data } = await request<MetaResponse>(
          config,
          `${prefix}/v1/meta?dataset=${encodeURIComponent(config.dataset)}`,
          {
            method: 'GET',
            kind: 'read',
          },
        )
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
