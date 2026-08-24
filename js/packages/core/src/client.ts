// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type {
  BarkparkClient,
  BarkparkClientConfig,
  BarkparkDocument,
  CommitOptions,
  DocsBuilder,
  ListenHandle,
  MetaResponse,
  MutateResult,
  PatchBuilder,
  Perspective,
  ListenFilter,
  ExportOptions,
  TransactionBuilder,
} from './types'
import { BarkparkValidationError } from './errors'
import { getDoc } from './doc'
import { searchDocuments, getSearchSuggestions } from './search'
import { getBacklinks } from './backlinks'
import { getRelated } from './related'
import { listTags, getTagDocs } from './tags'
import { getGraph, getOrphans, getDangling } from './graph'
import { getHistory, getRevision, restoreRevision } from './history'
import {
  registerUser,
  loginUser,
  getCurrentUser,
  logoutUser,
  enrollMfa,
  verifyMfa,
  disableMfa,
  verifyEmail,
  requestPasswordReset,
  resetPassword,
} from './auth'
import {
  uploadAsset,
  listAssets,
  getAsset,
  deleteAsset,
  updateAsset,
  checkoutAsset,
  undoCheckoutAsset,
  getAssetRelations,
  searchAssets,
  getAssetSearchSuggestions,
  listCollections,
  getCollection,
  getCollectionAssets,
  addCollectionMember,
  removeCollectionMember,
  shareCollection,
  revokeCollectionShare,
} from './media'
import { listSchemas, getSchema, upsertSchema, deleteSchema } from './schemas'
import { getAnalytics } from './analytics'
import {
  listWebhooks,
  getWebhook,
  createWebhook,
  updateWebhook,
  deleteWebhook,
} from './webhooks'
import { createDocsOperation } from './docs'
import type { DocsOperationOptions } from './docs'
import { createPatch } from './patch'
import { createTransaction } from './transaction'
import { publishDoc, unpublishDoc, discardDraftDoc } from './publish'
import { imageUrl as buildImageUrl } from './image-url'
import type { ImageRef, ImageUrlOptions } from './image-url'
import { scopePrefix } from './scope'
import { createListenHandle } from './listen'
import type { ListenOptions } from './listen'
import { exportDataset } from './export'
import { fetchRawDoc } from './fetchRaw'
import {
  listWorkspaces,
  listProjects,
  listDatasets,
  createWorkspace,
  createProject,
  type CreateProjectInput,
  type CreateWorkspaceInput,
  type Project,
  type Workspace,
  type Dataset,
} from './tenancy'
import { createHandshakeCache, type HandshakeCache } from './handshake'

// V3 token-leak defense (arpss-js-core-token-serialize-redact). The config is
// exposed as `client.config` with `token` an enumerable string, so
// JSON.stringify(client), util.inspect(client), or a React Flight (RSC->browser)
// serialization would otherwise ship the raw auth token. Attach redacting
// `toJSON` + Node inspect hooks BEFORE Object.freeze (methods cannot be added
// after freeze). Both hooks are NON-ENUMERABLE, so withConfig()'s
// `{ ...frozen, ...patch }` spread drops them — but `token` stays ENUMERABLE and
// survives the spread (a non-enumerable token would silently build a token-less
// derived client and break auth), and createClient re-attaches the hooks on every
// derived client. Direct `config.token` access (transport/listen/export) still
// returns the real value — only the serialization surfaces are redacted.
//
// SDK SECURITY NOTES — the two KNOWN edges of this cover, re-derived 2026-08-23:
//
// * structuredClone IGNORES toJSON by spec: structuredClone(client.config)
//   .token IS the raw token (run-confirmed on the current build;
//   arpss-js-structuredclone-residual-path). Standard Next App Router prop
//   serialization is Flight, which honors toJSON — structuredClone is a
//   NON-STANDARD path and no repo consumer structured-clones the client or its
//   config (grep-confirmed). The only structural cover would be a
//   non-enumerable/private token store, which breaks the withConfig spread —
//   a redesign, not a patch. token-leak-guard.test.ts pins this edge as an
//   HONEST CANARY so the limitation cannot be silently forgotten or silently
//   "fixed" without updating these notes.
//
// * React Flight honors this toJSON on the RSC wire (re-derived on the repo's
//   react/react-server-dom-webpack 19.2.5: dev AND prod builds ship
//   '[REDACTED]', never the raw token; dev additionally warns 'Objects with
//   toJSON methods are not supported' — arpss-js-rsc-tojson-durability). React
//   documents object-with-toJSON as UNSUPPORTED across the boundary, so this
//   coverage is best-effort: never pass the client/config as a Client
//   Component prop; the four-vector guard (JSON.stringify / util.inspect /
//   errors / URL) stays valid regardless of what React does.
const INSPECT_CUSTOM = Symbol.for('nodejs.util.inspect.custom')

function redactedConfig(config: BarkparkClientConfig): Record<string, unknown> {
  const clone: Record<string, unknown> = { ...config }
  if (typeof clone.token === 'string' && clone.token.length > 0) {
    clone.token = '[REDACTED]'
  }
  return clone
}

function freezeConfigWithRedaction(config: BarkparkClientConfig): Readonly<BarkparkClientConfig> {
  const copy = { ...config } as BarkparkClientConfig
  const hook = {
    value(this: BarkparkClientConfig) {
      return redactedConfig(this)
    },
    enumerable: false,
    writable: false,
    configurable: false,
  }
  Object.defineProperty(copy, 'toJSON', hook)
  Object.defineProperty(copy, INSPECT_CUSTOM, hook)
  return Object.freeze(copy)
}

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
  // present they must be non-empty slugs. Both-or-neither is enforced below:
  // scopePrefix() only emits scoped paths when the pair is set, so a lone slug
  // would silently fall back to the flat /v1 routes (always a misconfig).
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

  if ((config.workspace === undefined) !== (config.project === undefined)) {
    throw new BarkparkValidationError(
      'workspace and project must be set together (both = scoped routes, neither = flat /v1)',
      { field: config.workspace !== undefined ? 'project' : 'workspace' },
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
    throw new BarkparkValidationError("useCdn:true is incompatible with perspective:'drafts'", {
      field: 'useCdn',
    })
  }

  // A negative or NaN timeoutMs is worse than useless: transport arms a timeout
  // only when `timeoutMs > 0`, so a typo like -5000 or NaN silently DISABLES the
  // timeout and every request can hang forever. 0 is valid — documented as
  // disabling the timeout — so only reject non-finite/negative values.
  if (
    config.timeoutMs !== undefined &&
    (typeof config.timeoutMs !== 'number' ||
      !Number.isFinite(config.timeoutMs) ||
      config.timeoutMs < 0)
  ) {
    throw new BarkparkValidationError(
      'invalid timeoutMs: must be a non-negative finite number (0 disables the timeout)',
      { field: 'timeoutMs' },
    )
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

// Convert the structured ListenFilter array into the flat Record<string,unknown>
// that listen.ts URL encoder expects. Phase 1A listen supports eq-only matching —
// the `op` is type-pinned to 'eq', and a non-eq
// op (from an untyped JS caller) is still rejected eagerly here as defense-in-depth.
function filtersToRecord(filter: ListenFilter | undefined): Record<string, unknown> | undefined {
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
  const frozen: Readonly<BarkparkClientConfig> = freezeConfigWithRedaction(config)

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
      opts?: {
        expand?: string | string[]
        fields?: string | string[]
        signal?: AbortSignal
        perspective?: Perspective
      },
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
      opts?: {
        expand?: string | string[]
        fields?: string | string[]
        signal?: AbortSignal
        perspective?: Perspective
      },
    ): Promise<Array<T | null>> {
      // Fail closed on malformed input BEFORE any network call (parity with the
      // sibling reads). A non-string `type` collapses the query path; a bare string
      // `ids` slips past `.length === 0` (len 2) and dies later at `ids.map`.
      if (typeof type !== 'string' || type.length === 0) {
        throw new BarkparkValidationError('getDocuments requires a non-empty type', { field: 'type' })
      }
      if (!Array.isArray(ids)) {
        throw new BarkparkValidationError('getDocuments requires an array of ids', { field: 'ids' })
      }
      for (const id of ids) {
        if (typeof id !== 'string' || id.length === 0) {
          throw new BarkparkValidationError('getDocuments requires non-empty string ids', {
            field: 'ids',
          })
        }
      }
      if (ids.length === 0) return []
      // Batch-fetch by id-list (one request per 1000, the server's max page) and
      // re-key by `_id`, then map back to the INPUT order with null for any missing
      // id — Sanity's getDocuments contract, over the `.in('_id', …)` filter.
      // `expand`/`fields`/`signal`/`perspective` ride the same query builder as the other reads.
      const docOpts: DocsOperationOptions = {}
      if (opts?.signal !== undefined) docOpts.signal = opts.signal
      if (opts?.perspective !== undefined) docOpts.perspective = opts.perspective
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
    getSearchSuggestions(prefix, opts) {
      return getSearchSuggestions(frozen, prefix, opts)
    },
    getBacklinks(id, opts) {
      return getBacklinks(frozen, id, opts)
    },
    getRelated(id, opts) {
      return getRelated(frozen, id, opts)
    },
    listTags(opts) {
      return listTags(frozen, opts)
    },
    getTagDocs(tag, opts) {
      return getTagDocs(frozen, tag, opts)
    },
    getGraph(id, opts) {
      return getGraph(frozen, id, opts)
    },
    getOrphans(opts) {
      return getOrphans(frozen, opts)
    },
    getDangling(opts) {
      return getDangling(frozen, opts)
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
      register(email, password, opts) {
        return registerUser(frozen, email, password, opts)
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
      enrollMfa(password, opts) {
        return enrollMfa(frozen, password, opts)
      },
      verifyMfa(secret, code, password, opts) {
        return verifyMfa(frozen, secret, code, password, opts)
      },
      disableMfa(password, opts) {
        return disableMfa(frozen, password, opts)
      },
      verifyEmail(token, opts) {
        return verifyEmail(frozen, token, opts)
      },
      requestPasswordReset(email, opts) {
        return requestPasswordReset(frozen, email, opts)
      },
      resetPassword(token, password, opts) {
        return resetPassword(frozen, token, password, opts)
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
    updateAsset(id, metadata, opts) {
      return updateAsset(frozen, id, metadata, opts)
    },
    checkoutAsset(id, opts) {
      return checkoutAsset(frozen, id, opts)
    },
    undoCheckoutAsset(id, opts) {
      return undoCheckoutAsset(frozen, id, opts)
    },
    getAssetRelations(id, opts) {
      return getAssetRelations(frozen, id, opts)
    },
    searchAssets(q, opts) {
      return searchAssets(frozen, q, opts)
    },
    getAssetSearchSuggestions(prefix, opts) {
      return getAssetSearchSuggestions(frozen, prefix, opts)
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
    addCollectionMember(id, assetId, opts) {
      return addCollectionMember(frozen, id, assetId, opts)
    },
    removeCollectionMember(id, assetId, opts) {
      return removeCollectionMember(frozen, id, assetId, opts)
    },
    shareCollection(id, opts) {
      return shareCollection(frozen, id, opts)
    },
    revokeCollectionShare(id, opts) {
      return revokeCollectionShare(frozen, id, opts)
    },
    imageUrl(asset: ImageRef | null | undefined, opts?: ImageUrlOptions): string | null {
      // Default the origin to the configured projectUrl so callers get absolute URLs,
      // and prepend the workspace/project scope prefix so scoped clients emit the
      // scoped rendition route (the flat /media/renditions/:id/:preset route is pinned
      // to the Default workspace). scopePrefix() is '' for flat clients — no-op there.
      return buildImageUrl(asset, {
        baseUrl: frozen.projectUrl,
        pathPrefix: scopePrefix(frozen),
        ...opts,
      })
    },
    schemas(opts) {
      return listSchemas(frozen, opts)
    },
    getSchema(name, opts) {
      return getSchema(frozen, name, opts)
    },
    upsertSchema(schema) {
      return upsertSchema(frozen, schema)
    },
    deleteSchema(name) {
      return deleteSchema(frozen, name)
    },
    getAnalytics(opts) {
      return getAnalytics(frozen, opts)
    },
    listWebhooks(opts) {
      return listWebhooks(frozen, opts)
    },
    getWebhook(id, opts) {
      return getWebhook(frozen, id, opts)
    },
    createWebhook(input, opts) {
      return createWebhook(frozen, input, opts)
    },
    updateWebhook(id, input, opts) {
      return updateWebhook(frozen, id, input, opts)
    },
    deleteWebhook(id, opts) {
      return deleteWebhook(frozen, id, opts)
    },
    patch(id: string, type: string): PatchBuilder {
      return createPatch(frozen, id, type)
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
    async publish(id: string, type: string, opts?: CommitOptions): Promise<MutateResult> {
      return publishDoc(frozen, id, type, opts)
    },
    async unpublish(id: string, type: string, opts?: CommitOptions): Promise<MutateResult> {
      return unpublishDoc(frozen, id, type, opts)
    },
    async discardDraft(id: string, type: string, opts?: CommitOptions): Promise<MutateResult> {
      return discardDraftDoc(frozen, id, type, opts)
    },
    listen<T = BarkparkDocument>(type?: string, filter?: ListenFilter, opts?: ListenOptions): ListenHandle<T> {
      return createListenHandle<T>(frozen, type, filtersToRecord(filter), opts)
    },
    exportDataset(opts?: ExportOptions): AsyncGenerator<BarkparkDocument, void, unknown> {
      return exportDataset(frozen, opts)
    },
    async fetchRaw<T = Response>(path: string, init?: RequestInit): Promise<T> {
      const response = await fetchRawDoc(frozen, path, init)
      return response as unknown as T
    },
    async listWorkspaces(opts?: { signal?: AbortSignal }): Promise<Workspace[]> {
      return listWorkspaces(frozen, opts)
    },
    async listProjects(
      workspaceSlug: string,
      opts?: { signal?: AbortSignal },
    ): Promise<Project[]> {
      return listProjects(frozen, workspaceSlug, opts)
    },
    async listDatasets(
      workspaceSlug: string,
      projectSlug: string,
      opts?: { signal?: AbortSignal },
    ): Promise<Dataset[]> {
      return listDatasets(frozen, workspaceSlug, projectSlug, opts)
    },
    async createWorkspace(
      attrs: CreateWorkspaceInput,
      opts?: { signal?: AbortSignal },
    ): Promise<Workspace> {
      return createWorkspace(frozen, attrs, opts)
    },
    async createProject(
      workspaceSlug: string,
      attrs: CreateProjectInput,
      opts?: { signal?: AbortSignal },
    ): Promise<Project> {
      return createProject(frozen, workspaceSlug, attrs, opts)
    },
    handshake(): Promise<MetaResponse> {
      return handshakeCache.get(frozen)
    },
    __handshakeCache: handshakeCache,
  }

  return client
}
