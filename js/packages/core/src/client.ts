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
import { searchDocuments } from './search'
import { getBacklinks } from './backlinks'
import { getHistory, getRevision, restoreRevision } from './history'
import { registerUser, loginUser, getCurrentUser, logoutUser } from './auth'
import {
  uploadAsset,
  listAssets,
  getAsset,
  deleteAsset,
  listCollections,
  getCollection,
  getCollectionAssets,
} from './media'
import { listSchemas, getSchema } from './schemas'
import { createDocsOperation } from './docs'
import type { DocsOperationOptions } from './docs'
import { createPatch } from './patch'
import { createTransaction } from './transaction'
import { publishDoc, unpublishDoc, discardDraftDoc } from './publish'
import { imageUrl as buildImageUrl } from './image-url'
import type { ImageRef, ImageUrlOptions } from './image-url'
import { createListenHandle } from './listen'
import { fetchRawDoc } from './fetchRaw'
import {
  listWorkspaces,
  listProjects,
  createWorkspace,
  createProject,
  type CreateProjectInput,
  type CreateWorkspaceInput,
  type Project,
  type Workspace,
} from './tenancy'
import { createHandshakeCache, type HandshakeCache } from './handshake'

const API_VERSION_RE = /^\d{4}-\d{2}-\d{2}$/
const DATASET_RE = /^[a-z0-9][a-z0-9_-]*$/
// Workspace / project slugs mirror DATASET_RE — lowercase, leading alnum, then alnum/_/-.
const SLUG_RE = /^[a-z0-9][a-z0-9_-]*$/
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

  if (
    typeof config.dataset !== 'string' ||
    config.dataset.length === 0 ||
    !DATASET_RE.test(config.dataset)
  ) {
    throw new BarkparkValidationError('invalid dataset: must match /^[a-z0-9][a-z0-9_-]*$/', {
      field: 'dataset',
    })
  }

  // workspace / project are optional (back-compat with flat /v1 routes). When
  // present they must be non-empty slugs. They are independent fields here;
  // scopePrefix() decides whether scoped paths are emitted (requires both).
  if (config.workspace !== undefined) {
    if (
      typeof config.workspace !== 'string' ||
      config.workspace.length === 0 ||
      !SLUG_RE.test(config.workspace)
    ) {
      throw new BarkparkValidationError('invalid workspace: must match /^[a-z0-9][a-z0-9_-]*$/', {
        field: 'workspace',
      })
    }
  }

  if (config.project !== undefined) {
    if (
      typeof config.project !== 'string' ||
      config.project.length === 0 ||
      !SLUG_RE.test(config.project)
    ) {
      throw new BarkparkValidationError('invalid project: must match /^[a-z0-9][a-z0-9_-]*$/', {
        field: 'project',
      })
    }
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
    throw new BarkparkValidationError("useCdn:true is incompatible with perspective:'drafts'", {
      field: 'useCdn',
    })
  }

  // Not a throw — withConfig({perspective:'drafts'}) before setting a token is
  // a legitimate construction order — but it must be LOUD: the server pins
  // anonymous reads to the published perspective, so a drafts/raw client
  // without a token doesn't error, it silently reads published documents.
  if (
    (config.perspective === 'drafts' || config.perspective === 'raw') &&
    config.token === undefined
  ) {
    console.warn(
      `[barkpark] perspective '${config.perspective}' without a token: ` +
        'the server pins anonymous reads to published — set `token` to read drafts',
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
    async doc<T = BarkparkDocument>(
      type: string,
      id: string,
      opts?: { expand?: string | string[]; fields?: string | string[] },
    ): Promise<T | null> {
      const { data } = await getDoc<T>(frozen, type, id, opts)
      return data
    },
    docs<T = BarkparkDocument>(type: string, opts?: DocsOperationOptions): DocsBuilder<T> {
      return createDocsOperation<T>(frozen, type, opts)
    },
    async getDocuments<T = BarkparkDocument>(
      type: string,
      ids: string[],
      opts?: { expand?: string | string[]; fields?: string | string[]; signal?: AbortSignal },
    ): Promise<Array<T | null>> {
      if (ids.length === 0) return []
      // Batch-fetch by id-list (one request per 1000, the server's max page) and
      // re-key by `_id`, then map back to the INPUT order with null for any missing
      // id — Sanity's getDocuments contract, over the `.in('_id', …)` filter.
      // `expand`/`fields`/`signal` ride the same query builder as the other reads.
      const docOpts = opts?.signal !== undefined ? { signal: opts.signal } : undefined
      const CHUNK = 1000
      const byId = new Map<string, T>()
      for (let i = 0; i < ids.length; i += CHUNK) {
        const chunk = ids.slice(i, i + CHUNK)
        const q = createDocsOperation<T>(frozen, type, docOpts).in('_id', chunk).limit(chunk.length)
        if (opts?.expand) q.expand(opts.expand)
        if (opts?.fields) q.select(opts.fields)
        const docs = await q.find()
        for (const d of docs) {
          const did = (d as { _id?: string })._id
          if (did) byId.set(did, d)
        }
      }
      return ids.map((id) => byId.get(id) ?? null)
    },
    search(q, opts) {
      return searchDocuments(frozen, q, opts)
    },
    getBacklinks(id, opts) {
      return getBacklinks(frozen, id, opts)
    },
    getHistory(type, id, opts) {
      return getHistory(frozen, type, id, opts)
    },
    getRevision(revId, opts) {
      return getRevision(frozen, revId, opts)
    },
    restoreRevision(revId, type, opts) {
      return restoreRevision(frozen, revId, type, opts)
    },
    auth: {
      register(email, password) {
        return registerUser(frozen, email, password)
      },
      login(email, password, opts) {
        return loginUser(frozen, email, password, opts)
      },
      me(opts) {
        return getCurrentUser(frozen, opts)
      },
      logout(opts) {
        return logoutUser(frozen, opts)
      },
    },
    uploadAsset(file, opts) {
      return uploadAsset(frozen, file, opts)
    },
    listAssets(opts) {
      return listAssets(frozen, opts)
    },
    getAsset(id, opts) {
      return getAsset(frozen, id, opts)
    },
    deleteAsset(id, opts) {
      return deleteAsset(frozen, id, opts)
    },
    listCollections(opts) {
      return listCollections(frozen, opts)
    },
    getCollection(id, opts) {
      return getCollection(frozen, id, opts)
    },
    getCollectionAssets(id, opts) {
      return getCollectionAssets(frozen, id, opts)
    },
    imageUrl(asset: ImageRef | null | undefined, opts?: ImageUrlOptions): string | null {
      // Default the origin to the configured projectUrl so callers get absolute URLs.
      return buildImageUrl(asset, { baseUrl: frozen.projectUrl, ...opts })
    },
    schemas() {
      return listSchemas(frozen)
    },
    getSchema(name) {
      return getSchema(frozen, name)
    },
    patch(id: string): PatchBuilder {
      return createPatch(frozen, id)
    },
    transaction(): TransactionBuilder {
      return createTransaction(frozen)
    },
    // Single-mutation conveniences — each is one atomic transaction commit.
    create(doc, opts) {
      return createTransaction(frozen).create(doc).commit(opts)
    },
    createOrReplace(doc, opts) {
      return createTransaction(frozen).createOrReplace(doc).commit(opts)
    },
    createIfNotExists(doc, opts) {
      return createTransaction(frozen).createIfNotExists(doc).commit(opts)
    },
    delete(id, type, opts) {
      // `opts` carries the per-op `ifMatch` (used by `.delete`) plus the commit
      // controls retry/idempotencyKey/timeoutMs (used by `.commit`).
      return createTransaction(frozen).delete(id, type, opts).commit(opts)
    },
    async publish(id: string, type: string): Promise<MutateResult> {
      return publishDoc(frozen, id, type)
    },
    async unpublish(id: string, type: string): Promise<MutateResult> {
      return unpublishDoc(frozen, id, type)
    },
    async discardDraft(id: string, type: string): Promise<MutateResult> {
      return discardDraftDoc(frozen, id, type)
    },
    listen<T = BarkparkDocument>(type?: string, filter?: QueryOptions['filters']): ListenHandle<T> {
      return createListenHandle<T>(frozen, type, filtersToRecord(filter))
    },
    async fetchRaw<T = unknown>(path: string, init?: RequestInit): Promise<T> {
      const response = await fetchRawDoc(frozen, path, init)
      return response as unknown as T
    },
    async listWorkspaces(): Promise<Workspace[]> {
      return listWorkspaces(frozen)
    },
    async listProjects(workspaceSlug: string): Promise<Project[]> {
      return listProjects(frozen, workspaceSlug)
    },
    async createWorkspace(attrs: CreateWorkspaceInput): Promise<Workspace> {
      return createWorkspace(frozen, attrs)
    },
    async createProject(workspaceSlug: string, attrs: CreateProjectInput): Promise<Project> {
      return createProject(frozen, workspaceSlug, attrs)
    },
    handshake(): Promise<MetaResponse> {
      return handshakeCache.get(frozen)
    },
    __handshakeCache: handshakeCache,
  }

  return client
}
