/**
 * Public type surface for @barkpark/core v0.1.
 * Derived from ADRs 002/005/006/007/009/010/011. Do not add shape-breaking
 * changes without an ADR amendment.
 */

import type { CreateProjectInput, CreateWorkspaceInput, Project, Workspace } from './tenancy'
import type { ImageRef, ImageUrlOptions } from './image-url'

/** YYYY-MM-DD template literal. Runtime check in createClient validates pattern. */
export type ApiVersion = `${number}-${number}-${number}`

/** Phoenix perspectives (ADR-004 §Decision). */
export type Perspective = 'published' | 'drafts' | 'raw'

/** System order fields (kept as literals for autocomplete). */
export type OrderField = '_updatedAt' | '_createdAt'
export type OrderDirection = 'asc' | 'desc'
// System fields keep autocomplete; `(string & {})` also admits any document
// field as `<field>:asc|desc` (e.g. 'title:asc') — query_controller.ex resolves
// it. The builder's `.order()` validates the shape at runtime.
export type OrderSpec = `${OrderField}:${OrderDirection}` | (string & {})

/** Filter operators Phoenix supports (content/query.ex apply_field_op). */
export type FilterOp =
  | 'eq'
  | 'neq'
  | 'in'
  | 'nin'
  | 'has'
  | 'contains'
  | 'startsWith'
  | 'endsWith'
  | 'gt'
  | 'gte'
  | 'lt'
  | 'lte'

/**
 * @internal
 *
 * This API is internal to @barkpark/core and may change without notice.
 * Use the public client API. These types describe transport internals and
 * may change. (Observability hook surfaces — ADR-010.)
 */
export interface RequestContext {
  method: string
  url: string
  headers: Record<string, string>
  body?: unknown
  attempt: number // 1-based; retries increment
  startedAt: number // performance.now()
  requestId?: string // X-Request-ID echoed to caller
}

/**
 * @internal
 *
 * This API is internal to @barkpark/core and may change without notice.
 * Use the public client API. These types describe transport internals and
 * may change.
 */
export interface ResponseContext {
  status: number
  ok: boolean
  url: string
  headers: Record<string, string>
  body?: unknown // parsed JSON when content-type permits; undefined for SSE/binary
  requestId?: string // from X-Request-ID
  etag?: string // from ETag header (unquoted)
  syncTags?: string[] // from envelope
  schemaHash?: string // from envelope (ADR-011 drift detection)
  durationMs: number // performance.now() - startedAt
  attempt: number
}

export interface BarkparkHooks {
  onBeforeRequest?: (ctx: RequestContext) => void | Promise<void>
  onResponse?: (ctx: ResponseContext) => void | Promise<void>
}

/** Config passed to createClient. */
export interface BarkparkClientConfig extends BarkparkHooks {
  projectUrl: string // e.g. 'http://89.167.28.206:4000' — no trailing slash
  workspace?: string // optional slug; scopes paths to /w/:workspace/p/:project (back-compat: omit for flat /v1)
  project?: string // optional slug; both workspace + project required together for scoped paths
  dataset: string // 'production'
  apiVersion: ApiVersion // REQUIRED, YYYY-MM-DD
  token?: string // Bearer for write + listen + admin surfaces
  useCdn?: boolean // reserved — guard rejects useCdn:true + perspective:'drafts'
  perspective?: Perspective // default 'published'
  timeoutMs?: number // reads: 30000, writes: 60000 (defaults applied inside transport)
  requestTagPrefix?: string // X-Barkpark-Request-Tag: <prefix>-<uuid> for observability (ADR-010); default 'bp', set '' to disable
  fetch?: typeof globalThis.fetch // user override (MSW, tracing)
}

/** Filter op predicates (input to fluent builder). */
export type FilterValue =
  | string
  | number
  | boolean
  | null
  | ReadonlyArray<string | number | boolean>

export interface QueryOptions {
  perspective?: Perspective
  order?: OrderSpec
  limit?: number // clamped 1..1000 server-side
  offset?: number // >= 0
  filters?: Array<{ field: string; op: FilterOp; value: FilterValue }>
}

/** A raw document envelope as returned by Phoenix. */
export interface BarkparkDocument {
  _id: string
  _type: string
  _rev: string
  _draft: boolean
  _publishedId: string
  _createdAt: string
  _updatedAt: string
  [field: string]: unknown
}

/**
 * Query endpoint envelope (Phoenix query_controller).
 * Shape is flat — fields live at the top level, not under a `result` wrapper.
 * Verified against GET /v1/data/query/:dataset/:type on the live API (2026-04).
 */
export interface QueryEnvelope<T = BarkparkDocument> {
  perspective: Perspective
  documents: T[]
  count: number
  limit: number
  offset: number
}

/**
 * @deprecated Phoenix returns flat envelopes. `query` responses are {@link QueryEnvelope};
 * `doc` responses are the document body directly. This type is retained only as a type alias
 * for the document body and will be removed in a future preview.
 */
export type ReadEnvelope<T = unknown> = T

/** Mutate envelope (Phoenix mutate_controller). */
export interface MutateResult {
  id: string
  operation:
    | 'create'
    | 'createOrReplace'
    | 'replace'
    | 'update'
    | 'publish'
    | 'unpublish'
    | 'discardDraft'
    | 'delete'
    | 'noop'
  document: BarkparkDocument
}

export interface MutateEnvelope {
  transactionId: string
  results: MutateResult[]
}

/** Options for `client.uploadAsset()`. */
export interface UploadOptions {
  /** Override the filename sent in the multipart part (defaults to the file's `name`). */
  filename?: string
  /** AbortSignal forwarded to fetch. */
  signal?: AbortSignal
  /** Upload timeout (ms). Defaults to 120000 (uploads run longer than mutations);
   *  raise it for large transfers, or set `0` to disable. */
  timeoutMs?: number
}

/** A media asset returned by `client.uploadAsset()` (shape per the server's AssetResponse). */
export interface MediaAsset {
  _id?: string
  url?: string
  [key: string]: unknown
}

/** A page of media assets from `client.listAssets()`. */
export interface MediaAssetPage {
  assets: MediaAsset[]
  count: number
  limit: number
  offset: number
}

/** Options for `client.listAssets()`. */
export interface ListAssetsOptions {
  /** Max assets to return (server default 50). */
  limit?: number
  /** Assets to skip — paginate with `limit` (`count` is the total). */
  offset?: number
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** Options for `client.getAsset()` / `client.deleteAsset()`. */
export interface AssetOptions {
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** A media collection (folder / smart-folder) from `client.listCollections()`. */
export interface MediaCollection {
  id: string
  title: string | null
  /** `"folder"` (default) or a smart-folder kind. */
  kind: string
  shareEnabled: boolean
  createdAt: string
  updatedAt: string
  /** slug / description / parent / coverAsset / virtualFilter / sortOrder / … */
  [key: string]: unknown
}

/** A page of media collections from `client.listCollections()`. */
export interface MediaCollectionPage {
  collections: MediaCollection[]
  count: number
  limit: number
  offset: number
}

/** A collection's assets from `client.getCollectionAssets()`. */
export interface MediaCollectionAssets {
  collectionId: string
  hits: MediaAsset[]
  total: number
  limit?: number
  offset?: number
  facets?: unknown
}

/** Options for `client.getCollectionAssets()`. */
export interface CollectionAssetsOptions {
  /** Max assets to return. */
  limit?: number
  /** Assets to skip — paginate with `limit` (`total` is the count). */
  offset?: number
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** A single inbound reference from `client.getBacklinks()`. */
export interface Backlink {
  /** The referencing document's id. */
  from_doc_id: string
  /** Its title (falls back to the id when untitled). */
  title: string
  /** Its document type. */
  type?: string
  /** The reference field / edge kind that links it. */
  kind?: string
  [key: string]: unknown
}

/** The result of `client.getBacklinks()` — documents that reference the target. */
export interface BacklinksResult {
  backlinks: Backlink[]
  count: number
}

/** Options for `client.getBacklinks()`. */
export interface BacklinksOptions {
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** One entry in a document's revision history (`client.getHistory()` / `getRevision()`). */
export interface DocumentRevision {
  id: string
  /** What produced this revision: `'create'` / `'update'` / `'publish'` / … */
  action: string
  title: string | null
  /** ISO-8601 timestamp. */
  timestamp: string
  /** The document content at this revision — present on `getRevision()`, omitted in the list. */
  content?: Record<string, unknown>
  [key: string]: unknown
}

/** Result of `client.restoreRevision()` — the past version written back as a draft. */
export interface RestoreResult {
  restored: boolean
  document: BarkparkDocument
}

/** Options for `client.getHistory()`. */
export interface HistoryOptions {
  /** Max revisions to return. */
  limit?: number
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** Options for `client.getRevision()` / `client.restoreRevision()`. */
export interface RevisionOptions {
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** An authenticated user (`client.auth.me()` / the `user` in a login session). */
export interface AuthUser {
  id: string
  email: string
  /** Whether the email has been confirmed. */
  confirmed?: boolean
  /** Whether TOTP MFA is enrolled. */
  mfa?: boolean
  [key: string]: unknown
}

/** A logged-in session from `client.auth.login()`. */
export interface AuthSession {
  /** Bearer token for the session — set it as a new client's `token`. */
  token: string
  user: AuthUser
}

/** Result of `client.auth.register()` — intentionally generic (no email-existence leak). */
export interface AuthRegisterResult {
  user: { email: string; confirmed: boolean }
}

/** Options for `client.auth.login()`. */
export interface LoginOptions {
  /** Six-digit TOTP code, when the account has MFA enrolled. */
  totpCode?: string
  /** One-time MFA recovery code (TOTP fallback). */
  recoveryCode?: string
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** The user-auth surface, namespaced under `client.auth`. */
export interface BarkparkAuth {
  /** Register a new user (`POST /v1/auth/register`). */
  register(email: string, password: string): Promise<AuthRegisterResult>
  /** Log in; returns `{ token, user }` (`POST /v1/auth/login`). Throws `BarkparkAuthError` (code `mfa_required` when a TOTP code is needed). */
  login(email: string, password: string, opts?: LoginOptions): Promise<AuthSession>
  /** The current user, or `null` when not authenticated (`GET /v1/auth/me`). */
  me(opts?: { signal?: AbortSignal }): Promise<AuthUser | null>
  /** Revoke the current session (`DELETE /v1/auth/logout`). */
  logout(opts?: { signal?: AbortSignal }): Promise<void>
}

/** A content schema as serialized for the SDK (`client.schemas()` / `client.getSchema()`). */
export interface BarkparkSchema {
  id: string
  name: string
  title?: string
  visibility?: string
  schemaHash?: string
  fields: Array<{ name: string; type: string; [key: string]: unknown }>
  [key: string]: unknown
}

/** Options for `client.search()`. */
export interface SearchOptions {
  /** Max hits to return (server default 50). */
  limit?: number
  /** Hits to skip — paginate together with `limit` (the result's `count` is the total). */
  offset?: number
  /** Restrict the search to a single document type. */
  type?: string
  /** Perspective override for this search; defaults to the client's `perspective`. */
  perspective?: Perspective
  /** Search engine — `postgres` (default) or `indx`. */
  engine?: 'postgres' | 'indx'
  /** AbortSignal forwarded to fetch. */
  signal?: AbortSignal
}

/** Result of `client.search()` — full-text hits plus search metadata. */
export interface SearchResult<T = BarkparkDocument> {
  documents: T[]
  count: number
  query: string
  /** Per-field highlight snippets, when the engine provides them. */
  highlights?: Record<string, unknown>
  /** Corrected term when a spelling/synonym correction fired (else null). */
  correctedTo?: string | null
  /**
   * Facet buckets per dimension (e.g. `type` / `status` / `author`), each a
   * `{ label, count }` list ordered by count desc, over the match set. The
   * server computes these on every search — use them to build "N results across
   * these facets" filters.
   */
  facets?: Record<string, Array<{ label: string; count: number }>>
  /** The server's parse of the query (terms/phrases/operators) — for "searching
   *  for X" displays and debugging the analyzer. */
  parsedQuery?: Record<string, unknown>
  /** Spelling/synonym recovery detail beyond `correctedTo` (engine-specific). */
  recovery?: unknown
  /** Whether the engine capped the result/count scan — when set, `count` is a
   *  lower bound, not exact (engine-specific; indx surfaces it, postgres omits). */
  truncation?: unknown
  /** Server-side query latency in milliseconds. */
  ms?: number
}

/** /v1/meta response shape. */
export interface MetaResponse {
  minApiVersion: string
  maxApiVersion: string
  serverTime: string
  currentDatasetSchemaHash: string | Record<string, string>
}

/** SSE event yielded by client.listen(). */
export interface ListenEvent<T = BarkparkDocument> {
  eventId: string
  type: 'welcome' | 'mutation'
  mutation?: 'create' | 'update' | 'delete' | 'publish' | 'unpublish'
  documentId?: string
  rev?: string
  previousRev?: string | null
  result?: T
  syncTags?: string[]
}

/** listen() return value — AsyncIterable with manual unsubscribe. */
export interface ListenHandle<T = BarkparkDocument> extends AsyncIterable<ListenEvent<T>> {
  unsubscribe(): void
}

/** Commit options for patch / transaction. */
export interface CommitOptions {
  ifMatch?: string // per-op revision guard (32-hex _rev)
  retry?: boolean // opt-in write retry (default false per ADR-002 bullet 8)
  idempotencyKey?: string // caller-provided; when absent, retry=true auto-generates UUIDv7
  timeoutMs?: number // per-call override
}

/** Fluent single-document patch builder. Obtain via `client.patch(id)` or {@link createPatch}. */
export interface PatchBuilder {
  /** Merge shallow field updates into the patch. System fields (_id, _rev, …) are rejected. */
  set(fields: Record<string, unknown>): PatchBuilder
  /**
   * Increment numeric fields by the given deltas (a missing field counts as 0).
   * Composes with set/unset/dec in one commit.
   * @throws BarkparkValidationError on a non-object, system field, or non-finite delta.
   */
  inc(fields: Record<string, number>): PatchBuilder
  /**
   * Decrement numeric fields by the given deltas (a missing field counts as 0).
   * Composes with set/unset/inc in one commit.
   * @throws BarkparkValidationError on a non-object, system field, or non-finite delta.
   */
  dec(fields: Record<string, number>): PatchBuilder
  /**
   * Write fields only where the document doesn't already have them (fill
   * defaults). `set()` overrides `setIfMissing()` on the same key in one commit.
   * @throws BarkparkValidationError on a non-object or system field.
   */
  setIfMissing(fields: Record<string, unknown>): PatchBuilder
  /**
   * Remove content fields from the document. Keys must be a string array and may
   * not name a system field. May be combined with `set()` in one commit.
   * @throws BarkparkValidationError on a non-array, non-string key, or system field.
   */
  unset(keys: string[]): PatchBuilder
  /** @throws BarkparkValidationError — Phoenix Phase 1A does not implement array mutations. */
  insert(at: 'before' | 'after' | 'replace', selector: string, items: unknown[]): PatchBuilder
  /**
   * Append items to the END of a top-level array field. The `selector` is the
   * field (`'tags'` or `'tags[-1]'`); a missing field is created, a non-array
   * value is left untouched. Composes with the other ops in one commit.
   * @throws BarkparkValidationError on a non-array `items`, a nested/dotted
   *   selector, or a system field.
   */
  append(selector: string, items: unknown[]): PatchBuilder
  /**
   * Prepend items to the FRONT of a top-level array field (see {@link append}).
   * @throws BarkparkValidationError on a non-array `items`, a nested/dotted
   *   selector, or a system field.
   */
  prepend(selector: string, items: unknown[]): PatchBuilder
  /** @throws BarkparkValidationError — Phoenix Phase 1A does not implement patch.diffMatchPatch. */
  diffMatchPatch(fields: Record<string, string>): PatchBuilder
  /** Send the patch as a single-op mutation. Supply `ifMatch` for optimistic concurrency. */
  commit(opts?: CommitOptions): Promise<MutateResult>
}

/** Fluent list-query builder. Obtain via `client.docs(type)` or {@link createDocsOperation}. */
export interface DocsBuilder<T = BarkparkDocument> {
  /** Add a filter (`field op value`). Supported ops per {@link FilterOp}. */
  where(field: string, op: FilterOp, value: FilterValue): DocsBuilder<T>
  /** Sugar for `where(field, 'eq', value)`. */
  eq(field: string, value: string | number | boolean | null): DocsBuilder<T>
  /** Sugar for `where(field, 'neq', value)` — strict `!=`; NULL/absent rows are excluded. */
  neq(field: string, value: string | number | boolean | null): DocsBuilder<T>
  /** Sugar for `where(field, 'in', values)` — matches any listed value. */
  in(field: string, values: ReadonlyArray<string | number | boolean>): DocsBuilder<T>
  /** Sugar for `where(field, 'nin', values)` — excludes the listed values (NULL/absent rows too). */
  nin(field: string, values: ReadonlyArray<string | number | boolean>): DocsBuilder<T>
  /** Sugar for `where(field, 'has', value)` — array membership (the field's array contains `value`, as a `{_ref}` or scalar). */
  has(field: string, value: string | number | boolean): DocsBuilder<T>
  /** Sugar for `where(field, 'contains', value)` — substring match (case-insensitive). */
  contains(field: string, value: string): DocsBuilder<T>
  /** Sugar for `where(field, 'startsWith', value)` — prefix match (case-insensitive). */
  startsWith(field: string, value: string): DocsBuilder<T>
  /** Sugar for `where(field, 'endsWith', value)` — suffix match (case-insensitive). */
  endsWith(field: string, value: string): DocsBuilder<T>
  /** Sugar for `where(field, 'gt', value)`. */
  gt(field: string, value: string | number): DocsBuilder<T>
  /** Sugar for `where(field, 'gte', value)`. */
  gte(field: string, value: string | number): DocsBuilder<T>
  /** Sugar for `where(field, 'lt', value)`. */
  lt(field: string, value: string | number): DocsBuilder<T>
  /** Sugar for `where(field, 'lte', value)`. */
  lte(field: string, value: string | number): DocsBuilder<T>
  /**
   * Sort by any field, `<field>:asc|desc` (e.g. `title:asc`, `_updatedAt:desc`).
   * Chaining appends sort keys: `.order('status:asc').order('title:asc')` sorts by
   * status, then title as a tiebreak (multi-field sort).
   */
  order(spec: OrderSpec): DocsBuilder<T>
  /** Cap the result set. Server clamps to 1..1000. */
  limit(n: number): DocsBuilder<T>
  /** Skip N matches (paging). */
  offset(n: number): DocsBuilder<T>
  /**
   * Inline reference fields — single or `arrayOf`-of-reference — with their full
   * documents, depth 1. Each value may be a plain id string or a `{_ref}` object.
   * Pass one or more field names, e.g. `.expand('author')` or
   * `.expand(['author', 'tags'])`. A missing ref stays a raw id string.
   */
  expand(fields: string | string[]): DocsBuilder<T>
  /**
   * Return only the named fields (projection) instead of the whole document, for
   * smaller list-view payloads — `.select('title')` or `.select(['title', 'slug'])`.
   * System fields (`_id`, `_type`, `_rev`, …) are always included. Applied after
   * `expand`, so an expanded field survives if it's selected.
   */
  select(fields: string | string[]): DocsBuilder<T>
  /** Execute and return all matches. */
  find(): Promise<T[]>
  /** Execute with `limit:1` and return the first match or null. */
  findOne(): Promise<T | null>
  /**
   * Total number of documents matching the filters, ignoring `limit`/`offset`
   * — the count a paginator needs (`?count=true` server-side). One extra request.
   * Throws if the builder was created without a client (no count executor).
   */
  count(): Promise<number>
  /**
   * The page **and** the total match count in a single request (`?count=true`) —
   * the efficient pagination shape when you need both. Throws on a client-less
   * builder. Use `.find()` when you don't need the total.
   */
  findPage(): Promise<QueryPage<T>>
}

/** A page of query results plus the full match `total` — returned by `findPage()`. */
export interface QueryPage<T = BarkparkDocument> {
  documents: T[]
  total: number
  count: number
  limit: number
  offset: number
}

/** Multi-mutation transaction builder. All ops commit atomically. */
export interface TransactionBuilder {
  /** Append a `create` op. The server generates the id when not provided. */
  create(doc: Partial<BarkparkDocument> & { _type: string }): TransactionBuilder
  /** Append a `createOrReplace` op — server upserts the full document. */
  createOrReplace(doc: BarkparkDocument): TransactionBuilder
  /** Append a `createIfNotExists` op — creates the document only if `_id` is free (no-op otherwise). */
  createIfNotExists(doc: BarkparkDocument): TransactionBuilder
  /** Append a `patch` op. Call `.set()` on the inner builder; do NOT call its `.commit()`. */
  patch(
    id: string,
    build: (p: PatchBuilder) => PatchBuilder,
    opts?: { ifMatch?: string },
  ): TransactionBuilder
  /** Append a `publish` op (copies drafts.{id} → {id}). */
  publish(id: string, type: string): TransactionBuilder
  /** Append an `unpublish` op (moves {id} → drafts.{id}). */
  unpublish(id: string, type: string): TransactionBuilder
  /** Append a `discardDraft` op (drops drafts.{id}, leaving the published {id}). */
  discardDraft(id: string, type: string): TransactionBuilder
  /** Append a `delete` op. Supply `ifMatch` to guard. */
  delete(id: string, type: string, opts?: { ifMatch?: string }): TransactionBuilder
  /** Send the accumulated batch. All-or-nothing; returns the full {@link MutateEnvelope}. */
  commit(opts?: CommitOptions): Promise<MutateEnvelope>
}

/** Main client surface returned by {@link createClient}. */
export interface BarkparkClient {
  /** The frozen config this client was built from. */
  readonly config: Readonly<BarkparkClientConfig>
  /** Return a new client with the given config fields merged over the current ones. */
  withConfig(patch: Partial<BarkparkClientConfig>): BarkparkClient
  /** Fetch a single document by type + id. Returns `null` on 404. Pass
   *  `{ expand }` to inline reference fields (depth 1), e.g. `{ expand: 'author' }`,
   *  and/or `{ fields }` to project (return only those content fields). */
  doc<T = BarkparkDocument>(
    type: string,
    id: string,
    opts?: { expand?: string | string[]; fields?: string | string[] },
  ): Promise<T | null>
  /**
   * Start a filterable list-query over a type. Pass `{ perspective }` to override
   * the client perspective for this query, and/or `{ signal }` (an `AbortSignal`)
   * to make `.find()`/`.findOne()`/`.count()`/`.findPage()` cancellable.
   */
  docs<T = BarkparkDocument>(
    type: string,
    opts?: { perspective?: Perspective; signal?: AbortSignal },
  ): DocsBuilder<T>
  /**
   * Batch-fetch documents of `type` by id. Returns them in the SAME order as `ids`,
   * with `null` for any id that doesn't exist (Sanity's `getDocuments` contract).
   * Lists over ~1000 ids are fetched in chunks. Returns `[]` for an empty `ids`.
   * Pass `{ expand }` to inline reference fields, `{ fields }` to project, and/or
   * `{ signal }` (an `AbortSignal`) to cancel — the same as `doc()` / the query builder.
   */
  getDocuments<T = BarkparkDocument>(
    type: string,
    ids: string[],
    opts?: { expand?: string | string[]; fields?: string | string[]; signal?: AbortSignal },
  ): Promise<Array<T | null>>
  /** Full-text search across the dataset (`GET /v1/data/search`). */
  search<T = BarkparkDocument>(q: string, opts?: SearchOptions): Promise<SearchResult<T>>
  /** Upload a media asset (multipart `POST /v1/media/:dataset/upload`). `file` is a web `Blob`/`File`. */
  uploadAsset(file: Blob, opts?: UploadOptions): Promise<MediaAsset>
  /** List media assets in the dataset (`GET /v1/media/:dataset`). Paginate with `limit`/`offset`. */
  listAssets(opts?: ListAssetsOptions): Promise<MediaAssetPage>
  /** Fetch one media asset by id (`GET /v1/media/:dataset/:id`). Returns `null` on 404. */
  getAsset(id: string, opts?: AssetOptions): Promise<MediaAsset | null>
  /** Delete a media asset by id (`DELETE /v1/media/:dataset/:id`). Returns `{ deleted: id }`. */
  deleteAsset(id: string, opts?: AssetOptions): Promise<{ deleted: string }>
  /** List media collections (`GET /v1/media/:dataset/collections`). Paginate with `limit`/`offset`. */
  listCollections(opts?: ListAssetsOptions): Promise<MediaCollectionPage>
  /** Fetch one media collection by id (`GET /v1/media/:dataset/collections/:id`). Returns `null` on 404. */
  getCollection(id: string, opts?: AssetOptions): Promise<MediaCollection | null>
  /** List the assets in a media collection (`GET /v1/media/:dataset/collections/:id/assets`). */
  getCollectionAssets(id: string, opts?: CollectionAssetsOptions): Promise<MediaCollectionAssets>
  /** Documents that reference `id` — inbound references / backlinks (`GET /v1/data/backlinks/:dataset/:id`). */
  getBacklinks(id: string, opts?: BacklinksOptions): Promise<BacklinksResult>
  /** A document's revision history, newest first (`GET /v1/data/history/:dataset/:type/:id`). */
  getHistory(type: string, id: string, opts?: HistoryOptions): Promise<DocumentRevision[]>
  /** Fetch one revision with its content (`GET /v1/data/revision/:dataset/:revId`). Returns `null` on 404. */
  getRevision(revId: string, opts?: RevisionOptions): Promise<DocumentRevision | null>
  /** Restore a revision as a new draft (`POST /v1/data/revision/:dataset/:revId/restore`). */
  restoreRevision(revId: string, type: string, opts?: RevisionOptions): Promise<RestoreResult>
  /** User authentication — `register` / `login` / `me` / `logout` (`/v1/auth/*`). */
  auth: BarkparkAuth
  /**
   * Build a URL for a stored image field — the preset-based equivalent of Sanity's
   * `urlFor`. With `{ preset }` returns the rendition URL (`/media/renditions/<id>/<preset>`),
   * otherwise the original. `baseUrl` defaults to the client's `projectUrl`.
   */
  imageUrl(asset: ImageRef | null | undefined, opts?: ImageUrlOptions): string | null
  /** List all content schemas in the dataset (`GET /v1/schemas`) — for dynamic/generic UIs. */
  schemas(): Promise<BarkparkSchema[]>
  /** Fetch one schema by type name, or `null` if it doesn't exist. */
  getSchema(name: string): Promise<BarkparkSchema | null>
  /** Open a single-doc patch builder. */
  patch(id: string): PatchBuilder
  /** Open a multi-op transaction builder. */
  transaction(): TransactionBuilder
  /** Create one document — convenience for `transaction().create(doc).commit(opts)`.
   *  `opts` forwards to the commit (retry / idempotencyKey / timeoutMs). */
  create(
    doc: Partial<BarkparkDocument> & { _type: string },
    opts?: CommitOptions,
  ): Promise<MutateEnvelope>
  /** Create or replace one document by `_id` — single-op transaction convenience. */
  createOrReplace(doc: BarkparkDocument, opts?: CommitOptions): Promise<MutateEnvelope>
  /** Create one document only if its `_id` is free (no-op otherwise) — single-op convenience. */
  createIfNotExists(doc: BarkparkDocument, opts?: CommitOptions): Promise<MutateEnvelope>
  /** Delete one document by id + type — single-op convenience. `opts.ifMatch` guards the
   *  rev; retry / idempotencyKey / timeoutMs forward to the commit. */
  delete(id: string, type: string, opts?: CommitOptions): Promise<MutateEnvelope>
  /** Publish a draft. */
  publish(id: string, type: string): Promise<MutateResult>
  /** Unpublish (move back to draft). */
  unpublish(id: string, type: string): Promise<MutateResult>
  /** Discard a draft's unsaved edits — drops `drafts.{id}`, leaving the published `{id}`. */
  discardDraft(id: string, type: string): Promise<MutateResult>
  /** Open an SSE live-stream. Throws {@link BarkparkEdgeRuntimeError} in Workerd. */
  listen<T = BarkparkDocument>(type?: string, filter?: QueryOptions['filters']): ListenHandle<T>
  /** Escape hatch for arbitrary paths — bypasses envelope decoding. */
  fetchRaw<T = unknown>(path: string, init?: RequestInit): Promise<T>
  /**
   * List the workspaces the token can reach. Calls the top-level tenancy
   * endpoint `GET /api/workspaces` — not dataset-scoped, not scopePrefix-prefixed.
   */
  listWorkspaces(): Promise<Workspace[]>
  /**
   * List the projects under a workspace via `GET /api/workspaces/:slug/projects`.
   * Top-level tenancy endpoint — independent of the client's workspace/project scope.
   */
  listProjects(workspaceSlug: string): Promise<Project[]>
  /**
   * Create a workspace via `POST /api/workspaces` with `{ name, slug? }`. Returns the
   * created workspace. Top-level tenancy endpoint — token-authed, not dataset-scoped.
   */
  createWorkspace(attrs: CreateWorkspaceInput): Promise<Workspace>
  /**
   * Create a project under a workspace via `POST /api/workspaces/:slug/projects` with
   * `{ name, slug? }`. Returns the created project. Top-level tenancy endpoint — token-authed.
   */
  createProject(workspaceSlug: string, attrs: CreateProjectInput): Promise<Project>
}
