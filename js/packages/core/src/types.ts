/**
 * Public type surface for @barkpark/core v0.1.
 * Derived from ADRs 002/005/006/007/009/010/011. Do not add shape-breaking
 * changes without an ADR amendment.
 */

/** YYYY-MM-DD template literal. Runtime check in createClient validates pattern. */
export type ApiVersion = `${number}-${number}-${number}`

/** Phoenix perspectives (ADR-004 §Decision). */
export type Perspective = 'published' | 'drafts' | 'raw'

/** Order fields Phoenix accepts (query_controller.ex). */
export type OrderField = '_updatedAt' | '_createdAt'
export type OrderDirection = 'asc' | 'desc'
export type OrderSpec = `${OrderField}:${OrderDirection}`

/** Filter operators Phoenix supports (content.ex:121-159). Phase 1A set. */
export type FilterOp = 'eq' | 'in' | 'contains' | 'gt' | 'gte' | 'lt' | 'lte'

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
  attempt: number                // 1-based; retries increment
  startedAt: number              // performance.now()
  requestId?: string             // X-Request-ID echoed to caller
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
  body?: unknown                 // parsed JSON when content-type permits; undefined for SSE/binary
  requestId?: string             // from X-Request-ID
  etag?: string                  // from ETag header (unquoted)
  syncTags?: string[]            // from envelope
  schemaHash?: string            // from envelope (ADR-011 drift detection)
  durationMs: number             // performance.now() - startedAt
  attempt: number
}

export interface BarkparkHooks {
  onBeforeRequest?: (ctx: RequestContext) => void | Promise<void>
  onResponse?: (ctx: ResponseContext) => void | Promise<void>
}

/** Config passed to createClient. */
export interface BarkparkClientConfig extends BarkparkHooks {
  projectUrl: string                // e.g. 'http://89.167.28.206:4000' — no trailing slash
  dataset: string                   // 'production'
  apiVersion: ApiVersion            // REQUIRED, YYYY-MM-DD
  token?: string                    // Bearer for write + listen + admin surfaces
  useCdn?: boolean                  // reserved — guard rejects useCdn:true + perspective:'drafts'
  perspective?: Perspective         // default 'published'
  timeoutMs?: number                // reads: 30000, writes: 60000 (defaults applied inside transport)
  requestTagPrefix?: string         // default 'bp'; for observability tagging (ADR-010)
  fetch?: typeof globalThis.fetch   // user override (MSW, tracing)
}

/** Filter op predicates (input to fluent builder). */
export type FilterValue = string | number | boolean | null | ReadonlyArray<string | number | boolean>

export interface QueryOptions {
  perspective?: Perspective
  order?: OrderSpec
  limit?: number                    // clamped 1..1000 server-side
  offset?: number                   // >= 0
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
  operation: 'create' | 'createOrReplace' | 'replace' | 'update' | 'publish' | 'unpublish' | 'discardDraft' | 'delete' | 'noop'
  document: BarkparkDocument
}

export interface MutateEnvelope {
  transactionId: string
  results: MutateResult[]
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
  ifMatch?: string                  // per-op revision guard (32-hex _rev)
  retry?: boolean                   // opt-in write retry (default false per ADR-002 bullet 8)
  idempotencyKey?: string           // caller-provided; when absent, retry=true auto-generates UUIDv7
  timeoutMs?: number                // per-call override
}

/** Fluent single-document patch builder. Obtain via `client.patch(id)` or {@link createPatch}. */
export interface PatchBuilder {
  /** Merge shallow field updates into the patch. System fields (_id, _rev, …) are rejected. */
  set(fields: Record<string, unknown>): PatchBuilder
  /** @throws BarkparkValidationError — Phoenix Phase 1A does not implement patch.inc. */
  inc(fields: Record<string, number>): PatchBuilder
  /** Send the patch as a single-op mutation. Supply `ifMatch` for optimistic concurrency. */
  commit(opts?: CommitOptions): Promise<MutateResult>
}

/** Fluent list-query builder. Obtain via `client.docs(type)` or {@link createDocsOperation}. */
export interface DocsBuilder<T = BarkparkDocument> {
  /** Add a filter (`field op value`). Supported ops per {@link FilterOp}. */
  where(field: string, op: FilterOp, value: FilterValue): DocsBuilder<T>
  /** Sort by `_updatedAt` or `_createdAt` asc/desc. */
  order(spec: OrderSpec): DocsBuilder<T>
  /** Cap the result set. Server clamps to 1..1000. */
  limit(n: number): DocsBuilder<T>
  /** Skip N matches (paging). */
  offset(n: number): DocsBuilder<T>
  /** Execute and return all matches. */
  find(): Promise<T[]>
  /** Execute with `limit:1` and return the first match or null. */
  findOne(): Promise<T | null>
}

/** Multi-mutation transaction builder. All ops commit atomically. */
export interface TransactionBuilder {
  /** Append a `create` op. The server generates the id when not provided. */
  create(doc: Partial<BarkparkDocument> & { _type: string }): TransactionBuilder
  /** Append a `createOrReplace` op — server upserts the full document. */
  createOrReplace(doc: BarkparkDocument): TransactionBuilder
  /** Append a `patch` op. Call `.set()` on the inner builder; do NOT call its `.commit()`. */
  patch(id: string, build: (p: PatchBuilder) => PatchBuilder, opts?: { ifMatch?: string }): TransactionBuilder
  /** Append a `publish` op (copies drafts.{id} → {id}). */
  publish(id: string, type: string): TransactionBuilder
  /** Append an `unpublish` op (moves {id} → drafts.{id}). */
  unpublish(id: string, type: string): TransactionBuilder
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
  /** Fetch a single document by type + id. Returns `null` on 404. */
  doc<T = BarkparkDocument>(type: string, id: string): Promise<T | null>
  /** Start a filterable list-query over a type. */
  docs<T = BarkparkDocument>(type: string): DocsBuilder<T>
  /** Open a single-doc patch builder. */
  patch(id: string): PatchBuilder
  /** Open a multi-op transaction builder. */
  transaction(): TransactionBuilder
  /** Publish a draft. */
  publish(id: string, type: string): Promise<MutateResult>
  /** Unpublish (move back to draft). */
  unpublish(id: string, type: string): Promise<MutateResult>
  /** Open an SSE live-stream. Throws {@link BarkparkEdgeRuntimeError} in Workerd. */
  listen<T = BarkparkDocument>(type?: string, filter?: QueryOptions['filters']): ListenHandle<T>
  /** Escape hatch for arbitrary paths — bypasses envelope decoding. */
  fetchRaw<T = unknown>(path: string, init?: RequestInit): Promise<T>
}
