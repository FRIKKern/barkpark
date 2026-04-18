// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type {
  BarkparkClient,
  BarkparkClientConfig,
  BarkparkDocument,
  DocsBuilder,
  ListenHandle,
  MetaResponse,
  MutateResult,
  PatchBuilder,
  Perspective,
  QueryOptions,
  TransactionBuilder,
} from './types'
import { BarkparkValidationError } from './errors'
import { getDoc } from './doc'
import { createDocsOperation } from './docs'
import { createPatch } from './patch'
import { createTransaction } from './transaction'
import { publishDoc, unpublishDoc } from './publish'
import { createListenHandle } from './listen'
import { fetchRawDoc } from './fetchRaw'
import { createHandshakeCache, type HandshakeCache } from './handshake'

const API_VERSION_RE = /^\d{4}-\d{2}-\d{2}$/
const DATASET_RE = /^[a-z0-9][a-z0-9_-]*$/
const PERSPECTIVES: ReadonlyArray<Perspective> = ['published', 'drafts', 'raw']

function validateConfig(config: BarkparkClientConfig): void {
  if (typeof config.projectUrl !== 'string' || config.projectUrl.length === 0) {
    throw new BarkparkValidationError('invalid projectUrl: must be absolute http(s) URL', {
      field: 'projectUrl',
    })
  }
  let parsed: URL
  try {
    parsed = new URL(config.projectUrl)
  } catch {
    throw new BarkparkValidationError('invalid projectUrl: must be absolute http(s) URL', {
      field: 'projectUrl',
    })
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new BarkparkValidationError('invalid projectUrl: must be absolute http(s) URL', {
      field: 'projectUrl',
    })
  }

  if (typeof config.dataset !== 'string' || config.dataset.length === 0 || !DATASET_RE.test(config.dataset)) {
    throw new BarkparkValidationError(
      'invalid dataset: must match /^[a-z0-9][a-z0-9_-]*$/',
      { field: 'dataset' },
    )
  }

  if (typeof config.apiVersion !== 'string' || !API_VERSION_RE.test(config.apiVersion)) {
    throw new BarkparkValidationError('invalid apiVersion: must be YYYY-MM-DD', {
      field: 'apiVersion',
    })
  }

  if (config.token !== undefined) {
    if (typeof config.token !== 'string' || config.token.length === 0) {
      throw new BarkparkValidationError('invalid token: must be non-empty string', {
        field: 'token',
      })
    }
  }

  if (config.perspective !== undefined && !PERSPECTIVES.includes(config.perspective)) {
    throw new BarkparkValidationError(
      "invalid perspective: must be one of 'published' | 'drafts' | 'raw'",
      { field: 'perspective' },
    )
  }

  if (config.useCdn === true && config.perspective === 'drafts') {
    throw new BarkparkValidationError(
      "useCdn:true is incompatible with perspective:'drafts'",
      { field: 'useCdn' },
    )
  }
}

// Convert the structured QueryOptions filter array into the flat Record<string,unknown>
// that listen.ts URL encoder expects. Phase 1A listen supports eq-only matching (see
// w6.3-phoenix-contract.md §listen) — non-eq ops are rejected eagerly.
function filtersToRecord(
  filter: QueryOptions['filters'] | undefined,
): Record<string, unknown> | undefined {
  if (!filter || filter.length === 0) return undefined
  const out: Record<string, unknown> = {}
  for (const f of filter) {
    if (f.op !== 'eq') {
      throw new BarkparkValidationError(
        `listen filter op '${f.op}' is not supported in Phase 1A (eq only)`,
        { field: 'op' },
      )
    }
    out[f.field] = f.value
  }
  return out
}

/**
 * Extension surface added at runtime (not part of BarkparkClient interface).
 * `handshake()` fetches + caches /v1/meta; callers can opt-in for schema drift
 * checks or apiVersion negotiation.
 */
export interface BarkparkClientWithHandshake extends BarkparkClient {
  handshake(): Promise<MetaResponse>
  /** Internal — for tests that want to observe cache dedup. */
  readonly __handshakeCache: HandshakeCache
}

/**
 * Create a Barkpark client instance.
 *
 * Validates the config once, freezes it, and returns a client exposing the full
 * read / write / listen surface. Call once per project at module init — instances
 * are cheap to copy via `withConfig()` but not free to construct.
 *
 * The returned client also exposes `handshake()` and `__handshakeCache` via
 * {@link BarkparkClientWithHandshake} for advanced apiVersion/schema-drift flows.
 *
 * @throws BarkparkValidationError if any field fails schema validation.
 *
 * @example
 *   const bp = createClient({
 *     projectUrl: 'https://api.example.com',
 *     dataset:    'production',
 *     apiVersion: '2026-04-01',
 *     token:      process.env.BARKPARK_TOKEN,
 *   })
 *   const post = await bp.doc('post', 'p1')
 */
export function createClient(config: BarkparkClientConfig): BarkparkClient {
  validateConfig(config)
  const frozen: Readonly<BarkparkClientConfig> = Object.freeze({ ...config })

  // Per-instance handshake cache — scoped to this client so tests stay
  // deterministic and withConfig() gets a fresh cache (projectUrl/dataset
  // may change).
  const handshakeCache = createHandshakeCache()

  const client: BarkparkClientWithHandshake = {
    config: frozen,
    withConfig(patch) {
      return createClient({ ...frozen, ...patch })
    },
    async doc<T = BarkparkDocument>(type: string, id: string): Promise<T | null> {
      const { data } = await getDoc<T>(frozen, type, id)
      return data
    },
    docs<T = BarkparkDocument>(type: string): DocsBuilder<T> {
      return createDocsOperation<T>(frozen, type)
    },
    patch(id: string): PatchBuilder {
      return createPatch(frozen, id)
    },
    transaction(): TransactionBuilder {
      return createTransaction(frozen)
    },
    async publish(id: string, type: string): Promise<MutateResult> {
      return publishDoc(frozen, id, type)
    },
    async unpublish(id: string, type: string): Promise<MutateResult> {
      return unpublishDoc(frozen, id, type)
    },
    listen<T = BarkparkDocument>(
      type?: string,
      filter?: QueryOptions['filters'],
    ): ListenHandle<T> {
      return createListenHandle<T>(frozen, type, filtersToRecord(filter))
    },
    async fetchRaw<T = unknown>(path: string, init?: RequestInit): Promise<T> {
      const response = await fetchRawDoc(frozen, path, init)
      return response as unknown as T
    },
    handshake(): Promise<MetaResponse> {
      return handshakeCache.get(frozen)
    },
    __handshakeCache: handshakeCache,
  }

  return client
}
