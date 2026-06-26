/** A workspace the token can reach (GET /api/workspaces). */
interface Workspace {
    id: string;
    slug: string;
    name: string;
}
/** A project under a workspace (GET /api/workspaces/:slug/projects). */
interface Project {
    id: string;
    slug: string;
    name: string;
}
/** Envelope returned by GET /api/workspaces. */
interface ListWorkspacesEnvelope {
    workspaces: Workspace[];
}
/** Envelope returned by GET /api/workspaces/:slug/projects. */
interface ListProjectsEnvelope {
    workspace: Workspace;
    projects: Project[];
}
/** Attributes accepted by POST /api/workspaces. */
interface CreateWorkspaceInput {
    name: string;
    slug?: string;
}
/** Attributes accepted by POST /api/workspaces/:slug/projects. */
interface CreateProjectInput {
    name: string;
    slug?: string;
}
/** Envelope returned by POST /api/workspaces. */
interface CreateWorkspaceEnvelope {
    workspace: Workspace;
}
/** Envelope returned by POST /api/workspaces/:slug/projects. */
interface CreateProjectEnvelope {
    project: Project;
}
/**
 * List the workspaces the configured token can reach.
 *
 * Calls `GET /api/workspaces` — a top-level tenancy endpoint, so the path is
 * neither dataset-scoped nor `scopePrefix`-prefixed. Returns the typed
 * `workspaces` array unwrapped from the `{ workspaces }` envelope.
 * Prefer `client.listWorkspaces()`.
 */
declare function listWorkspaces(config: BarkparkClientConfig): Promise<Workspace[]>;
/**
 * List the projects under a workspace.
 *
 * Calls `GET /api/workspaces/:workspace_slug/projects` — top-level tenancy
 * endpoint (not dataset-scoped, not `scopePrefix`-prefixed). Returns the typed
 * `projects` array unwrapped from the `{ workspace, projects }` envelope.
 * Prefer `client.listProjects(workspaceSlug)`.
 */
declare function listProjects(config: BarkparkClientConfig, workspaceSlug: string): Promise<Project[]>;
/**
 * Create a workspace.
 *
 * Calls `POST /api/workspaces` with `{ name, slug? }` — a top-level tenancy
 * endpoint, so the path is neither dataset-scoped nor `scopePrefix`-prefixed.
 * Returns the created `Workspace` unwrapped from the `{ workspace }` envelope.
 * Token-authed via the shared Bearer plumbing. Prefer `client.createWorkspace(attrs)`.
 */
declare function createWorkspace(config: BarkparkClientConfig, attrs: CreateWorkspaceInput): Promise<Workspace>;
/**
 * Create a project under a workspace.
 *
 * Calls `POST /api/workspaces/:workspace_slug/projects` with `{ name, slug? }` —
 * top-level tenancy endpoint (not dataset-scoped, not `scopePrefix`-prefixed).
 * Returns the created `Project` unwrapped from the `{ project }` envelope.
 * Token-authed via the shared Bearer plumbing. Prefer `client.createProject(workspaceSlug, attrs)`.
 */
declare function createProject(config: BarkparkClientConfig, workspaceSlug: string, attrs: CreateProjectInput): Promise<Project>;

/**
 * Public type surface for @barkpark/core v0.1.
 * Derived from ADRs 002/005/006/007/009/010/011. Do not add shape-breaking
 * changes without an ADR amendment.
 */

/** YYYY-MM-DD template literal. Runtime check in createClient validates pattern. */
type ApiVersion = `${number}-${number}-${number}`;
/** Phoenix perspectives (ADR-004 §Decision). */
type Perspective = 'published' | 'drafts' | 'raw';
/** Order fields Phoenix accepts (query_controller.ex). */
type OrderField = '_updatedAt' | '_createdAt';
type OrderDirection = 'asc' | 'desc';
type OrderSpec = `${OrderField}:${OrderDirection}`;
/** Filter operators Phoenix supports (content.ex:121-159). Phase 1A set. */
type FilterOp = 'eq' | 'in' | 'contains' | 'gt' | 'gte' | 'lt' | 'lte';
/**
 * @internal
 *
 * This API is internal to @barkpark/core and may change without notice.
 * Use the public client API. These types describe transport internals and
 * may change. (Observability hook surfaces — ADR-010.)
 */
interface RequestContext {
    method: string;
    url: string;
    headers: Record<string, string>;
    body?: unknown;
    attempt: number;
    startedAt: number;
    requestId?: string;
}
/**
 * @internal
 *
 * This API is internal to @barkpark/core and may change without notice.
 * Use the public client API. These types describe transport internals and
 * may change.
 */
interface ResponseContext {
    status: number;
    ok: boolean;
    url: string;
    headers: Record<string, string>;
    body?: unknown;
    requestId?: string;
    etag?: string;
    syncTags?: string[];
    schemaHash?: string;
    durationMs: number;
    attempt: number;
}
interface BarkparkHooks {
    onBeforeRequest?: (ctx: RequestContext) => void | Promise<void>;
    onResponse?: (ctx: ResponseContext) => void | Promise<void>;
}
/** Config passed to createClient. */
interface BarkparkClientConfig extends BarkparkHooks {
    projectUrl: string;
    workspace?: string;
    project?: string;
    dataset: string;
    apiVersion: ApiVersion;
    token?: string;
    useCdn?: boolean;
    perspective?: Perspective;
    timeoutMs?: number;
    requestTagPrefix?: string;
    fetch?: typeof globalThis.fetch;
}
/** Filter op predicates (input to fluent builder). */
type FilterValue = string | number | boolean | null | ReadonlyArray<string | number | boolean>;
interface QueryOptions {
    perspective?: Perspective;
    order?: OrderSpec;
    limit?: number;
    offset?: number;
    filters?: Array<{
        field: string;
        op: FilterOp;
        value: FilterValue;
    }>;
}
/** A raw document envelope as returned by Phoenix. */
interface BarkparkDocument {
    _id: string;
    _type: string;
    _rev: string;
    _draft: boolean;
    _publishedId: string;
    _createdAt: string;
    _updatedAt: string;
    [field: string]: unknown;
}
/**
 * @deprecated Phoenix returns flat envelopes. `query` responses are {@link QueryEnvelope};
 * `doc` responses are the document body directly. This type is retained only as a type alias
 * for the document body and will be removed in a future preview.
 */
type ReadEnvelope<T = unknown> = T;
/** Mutate envelope (Phoenix mutate_controller). */
interface MutateResult {
    id: string;
    operation: 'create' | 'createOrReplace' | 'replace' | 'update' | 'publish' | 'unpublish' | 'discardDraft' | 'delete' | 'noop';
    document: BarkparkDocument;
}
interface MutateEnvelope {
    transactionId: string;
    results: MutateResult[];
}
/** /v1/meta response shape. */
interface MetaResponse {
    minApiVersion: string;
    maxApiVersion: string;
    serverTime: string;
    currentDatasetSchemaHash: string | Record<string, string>;
}
/** SSE event yielded by client.listen(). */
interface ListenEvent<T = BarkparkDocument> {
    eventId: string;
    type: 'welcome' | 'mutation';
    mutation?: 'create' | 'update' | 'delete' | 'publish' | 'unpublish';
    documentId?: string;
    rev?: string;
    previousRev?: string | null;
    result?: T;
    syncTags?: string[];
}
/** listen() return value — AsyncIterable with manual unsubscribe. */
interface ListenHandle<T = BarkparkDocument> extends AsyncIterable<ListenEvent<T>> {
    unsubscribe(): void;
}
/** Commit options for patch / transaction. */
interface CommitOptions {
    ifMatch?: string;
    retry?: boolean;
    idempotencyKey?: string;
    timeoutMs?: number;
}
/** Fluent single-document patch builder. Obtain via `client.patch(id)` or {@link createPatch}. */
interface PatchBuilder {
    /** Merge shallow field updates into the patch. System fields (_id, _rev, …) are rejected. */
    set(fields: Record<string, unknown>): PatchBuilder;
    /** @throws BarkparkValidationError — Phoenix Phase 1A does not implement patch.inc. */
    inc(fields: Record<string, number>): PatchBuilder;
    /** Send the patch as a single-op mutation. Supply `ifMatch` for optimistic concurrency. */
    commit(opts?: CommitOptions): Promise<MutateResult>;
}
/** Fluent list-query builder. Obtain via `client.docs(type)` or {@link createDocsOperation}. */
interface DocsBuilder<T = BarkparkDocument> {
    /** Add a filter (`field op value`). Supported ops per {@link FilterOp}. */
    where(field: string, op: FilterOp, value: FilterValue): DocsBuilder<T>;
    /** Sort by `_updatedAt` or `_createdAt` asc/desc. */
    order(spec: OrderSpec): DocsBuilder<T>;
    /** Cap the result set. Server clamps to 1..1000. */
    limit(n: number): DocsBuilder<T>;
    /** Skip N matches (paging). */
    offset(n: number): DocsBuilder<T>;
    /** Execute and return all matches. */
    find(): Promise<T[]>;
    /** Execute with `limit:1` and return the first match or null. */
    findOne(): Promise<T | null>;
}
/** Multi-mutation transaction builder. All ops commit atomically. */
interface TransactionBuilder {
    /** Append a `create` op. The server generates the id when not provided. */
    create(doc: Partial<BarkparkDocument> & {
        _type: string;
    }): TransactionBuilder;
    /** Append a `createOrReplace` op — server upserts the full document. */
    createOrReplace(doc: BarkparkDocument): TransactionBuilder;
    /** Append a `patch` op. Call `.set()` on the inner builder; do NOT call its `.commit()`. */
    patch(id: string, build: (p: PatchBuilder) => PatchBuilder, opts?: {
        ifMatch?: string;
    }): TransactionBuilder;
    /** Append a `publish` op (copies drafts.{id} → {id}). */
    publish(id: string, type: string): TransactionBuilder;
    /** Append an `unpublish` op (moves {id} → drafts.{id}). */
    unpublish(id: string, type: string): TransactionBuilder;
    /** Append a `delete` op. Supply `ifMatch` to guard. */
    delete(id: string, type: string, opts?: {
        ifMatch?: string;
    }): TransactionBuilder;
    /** Send the accumulated batch. All-or-nothing; returns the full {@link MutateEnvelope}. */
    commit(opts?: CommitOptions): Promise<MutateEnvelope>;
}
/** Main client surface returned by {@link createClient}. */
interface BarkparkClient {
    /** The frozen config this client was built from. */
    readonly config: Readonly<BarkparkClientConfig>;
    /** Return a new client with the given config fields merged over the current ones. */
    withConfig(patch: Partial<BarkparkClientConfig>): BarkparkClient;
    /** Fetch a single document by type + id. Returns `null` on 404. */
    doc<T = BarkparkDocument>(type: string, id: string): Promise<T | null>;
    /** Start a filterable list-query over a type. */
    docs<T = BarkparkDocument>(type: string): DocsBuilder<T>;
    /** Open a single-doc patch builder. */
    patch(id: string): PatchBuilder;
    /** Open a multi-op transaction builder. */
    transaction(): TransactionBuilder;
    /** Publish a draft. */
    publish(id: string, type: string): Promise<MutateResult>;
    /** Unpublish (move back to draft). */
    unpublish(id: string, type: string): Promise<MutateResult>;
    /** Open an SSE live-stream. Throws {@link BarkparkEdgeRuntimeError} in Workerd. */
    listen<T = BarkparkDocument>(type?: string, filter?: QueryOptions['filters']): ListenHandle<T>;
    /** Escape hatch for arbitrary paths — bypasses envelope decoding. */
    fetchRaw<T = unknown>(path: string, init?: RequestInit): Promise<T>;
    /**
     * List the workspaces the token can reach. Calls the top-level tenancy
     * endpoint `GET /api/workspaces` — not dataset-scoped, not scopePrefix-prefixed.
     */
    listWorkspaces(): Promise<Workspace[]>;
    /**
     * List the projects under a workspace via `GET /api/workspaces/:slug/projects`.
     * Top-level tenancy endpoint — independent of the client's workspace/project scope.
     */
    listProjects(workspaceSlug: string): Promise<Project[]>;
    /**
     * Create a workspace via `POST /api/workspaces` with `{ name, slug? }`. Returns the
     * created workspace. Top-level tenancy endpoint — token-authed, not dataset-scoped.
     */
    createWorkspace(attrs: CreateWorkspaceInput): Promise<Workspace>;
    /**
     * Create a project under a workspace via `POST /api/workspaces/:slug/projects` with
     * `{ name, slug? }`. Returns the created project. Top-level tenancy endpoint — token-authed.
     */
    createProject(workspaceSlug: string, attrs: CreateProjectInput): Promise<Project>;
}

interface HandshakeCache {
    /** Fetch + cache /v1/meta. Dedupes concurrent calls by projectUrl+dataset. */
    get(config: BarkparkClientConfig): Promise<MetaResponse>;
    /** Invalidate cache entry (used on SchemaMismatch). */
    invalidate(config: BarkparkClientConfig): void;
    /** Clear entire cache (used in tests). */
    clear(): void;
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
declare function createHandshakeCache(): HandshakeCache;

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
declare function createClient(config: BarkparkClientConfig): BarkparkClient;

/**
 * Path prefix that scopes every operation to a workspace + project.
 *
 * Returns `/w/${workspace}/p/${project}` only when BOTH `workspace` and
 * `project` are set on the config; otherwise returns `''` so callers fall back
 * to the flat `/v1/...` routes (back-compat). This is the single source the
 * per-operation path builders prepend — they must never compute the prefix
 * themselves.
 *
 * Lives in this leaf module (depends only on `./types`) so the per-operation
 * builders can import it without re-entering `./client`, which itself imports
 * the builders — keeping the dependency graph acyclic.
 *
 * @example
 *   scopePrefix({ workspace: 'acme', project: 'blog', ... }) // '/w/acme/p/blog'
 *   scopePrefix({ ...flatConfig })                           // ''
 */
declare function scopePrefix(config: BarkparkClientConfig): string;

/**
 * Low-level single-document patch builder.
 *
 * Prefer `client.patch(id)` in application code. Use this factory when you need
 * to compose a patch without a full client — e.g. inside a helper that only
 * has a config.
 *
 * `.set(fields)` validates + merges into an internal state. `.inc()` throws
 * synchronously: Phoenix Phase 1A does not implement `patch.inc`. `.commit()`
 * POSTs a single-mutation request and returns the resulting {@link MutateResult}.
 *
 * @throws BarkparkValidationError on missing id / forbidden set keys / empty commit.
 */
declare function createPatch(config: BarkparkClientConfig, id: string): PatchBuilder;

/**
 * Build a multi-mutation transaction.
 *
 * All ops commit atomically via Phoenix's `Repo.transaction` — any failure rolls
 * the entire batch back, so partial state is never persisted. Prefer
 * `client.transaction()`; this factory is for callers that only have a config.
 *
 * The inner `patch()` takes a builder callback: call `.set()` on the mini-builder
 * to accumulate field changes. Do NOT call the inner `.commit()` — use `tx.commit()`.
 *
 * @example
 *   await createTransaction(config)
 *     .patch('p1', (p) => p.set({ title: 'Hi' }), { ifMatch: rev })
 *     .publish('p1', 'post')
 *     .commit()
 */
declare function createTransaction(config: BarkparkClientConfig): TransactionBuilder;

interface DocsOperationOptions {
    perspective?: Perspective;
    signal?: AbortSignal;
}
/**
 * Build a fluent filter/order/limit/offset query against a document type.
 *
 * Returns a {@link DocsBuilder} whose `.find()` / `.findOne()` hit the wire.
 * `.where(field, op, value)` chains; see {@link FilterOp} for supported ops
 * (Phase 1A: `eq` | `in` | `contains` | `gt` | `gte` | `lt` | `lte`).
 * Prefer `client.docs(type)` — this factory is for config-only callers.
 */
declare function createDocsOperation<T = BarkparkDocument>(config: BarkparkClientConfig, type: string, opts?: DocsOperationOptions): DocsBuilder<T>;

interface DocResult<T> {
    data: T | null;
    /** Unquoted ETag ( = document _rev). Pass back as ifMatch on writes. */
    etag?: string;
}
interface GetDocOptions {
    perspective?: Perspective;
    signal?: AbortSignal;
}
/**
 * Fetch a single document by type + id.
 *
 * Returns `{ data: null }` on 404 (callers can treat missing as null) and
 * re-throws every other error per ADR-009. The response's `etag` (= `_rev`,
 * unquoted) is returned when the server included one — callers can pass it
 * back as `ifMatch` on subsequent writes to detect concurrent edits.
 *
 * Prefer `client.doc(type, id)` in app code.
 */
declare function getDoc<T = BarkparkDocument>(config: BarkparkClientConfig, type: string, id: string, opts?: GetDocOptions): Promise<DocResult<T>>;

/**
 * Publish a draft document.
 *
 * Copies `drafts.{id}` → `{id}` and deletes the draft in one Phoenix transaction.
 * Returns the resulting {@link MutateResult} with `operation: 'publish'`.
 * Prefer `client.publish(id, type)`.
 */
declare function publishDoc(config: BarkparkClientConfig, id: string, type: string): Promise<MutateResult>;
/**
 * Unpublish (move back to draft) a published document.
 *
 * Moves `{id}` → `drafts.{id}`. Returns the resulting {@link MutateResult}
 * with `operation: 'unpublish'`. Prefer `client.unpublish(id, type)`.
 */
declare function unpublishDoc(config: BarkparkClientConfig, id: string, type: string): Promise<MutateResult>;

/**
 * Escape hatch — returns the raw Response object for callers who need full control.
 * Pass any path relative to config.projectUrl (must start with '/').
 * Headers/body merge with transport defaults (Accept + Auth + request-tag).
 *
 * When the config sets both `workspace` and `project`, the caller-supplied path
 * is prefixed with `scopePrefix(config)` (`/w/<ws>/p/<project>`) so the escape
 * hatch routes through the same scoped surface as the typed read builders.
 * Flat configs leave the path untouched (back-compat). Paths that already carry
 * the scope prefix are left as-is to avoid double-prefixing.
 */
declare function fetchRawDoc(config: BarkparkClientConfig, path: string, init?: RequestInit): Promise<Response>;

interface ListenOptions {
    perspective?: Perspective;
    onUnsubscribe?: () => void;
    /** Max reconnect attempts after an *error* (clean stream close doesn't count). Default 5. 0 disables. */
    maxReconnects?: number;
    /** Base reconnect delay ms. Exponential backoff ×2, capped at 8000 ms. Default 500. */
    reconnectBaseMs?: number;
    signal?: AbortSignal;
}
/**
 * Open a live SSE stream against `/v1/data/listen/:dataset`.
 *
 * Returns a {@link ListenHandle} — an `AsyncIterable<ListenEvent<T>>` with a
 * `.unsubscribe()` method. Authors should `for await (const ev of handle)` and
 * call `handle.unsubscribe()` in their cleanup. Reconnects exponentially on
 * network drops (max 5 attempts by default) and sends `Last-Event-ID` on resume.
 *
 * Throws {@link BarkparkEdgeRuntimeError} synchronously in Workerd / Cloudflare
 * edge runtimes where streaming fetch is unavailable — poll via `client.docs()` instead.
 *
 * Prefer `client.listen(type, filter)` in app code.
 *
 * @see ADR-005 §SSE transport.
 */
declare function createListenHandle<T = BarkparkDocument>(config: BarkparkClientConfig, type?: string, filter?: Record<string, unknown>, opts?: ListenOptions): ListenHandle<T>;

interface FilterExpression {
    field: string;
    op: FilterOp;
    value: FilterValue;
}
interface BuilderState {
    filters: FilterExpression[];
    order?: OrderSpec;
    limit?: number;
    offset?: number;
}
declare function makeFilterExpression(field: string, op: FilterOp, value: FilterValue): FilterExpression;
/**
 * PURE factory — does NOT hit the network. Returns a builder over BuilderState.
 * The builder mutates its own internal state; `.where(...).order(...)` chains
 * return the same instance (cheap, matches single-chain usage in the client).
 */
declare function createDocsBuilder<T = BarkparkDocument>(executor: (state: BuilderState) => Promise<T[]>): DocsBuilder<T>;
/**
 * Encode BuilderState as a Phoenix-compatible query string.
 *
 * Phoenix parser (api/lib/barkpark_web/controllers/query_controller.ex:178-191
 * + api/lib/barkpark/content.ex:113-158) expects nested-map encoding:
 *
 *   filter[<field>][<op>]=<value>      // specific op
 *   filter[<field>]=<value>            // shorthand: op defaults to 'eq'
 *
 * For `in`, the value is a comma-joined string; Phoenix splits it
 * (normalize_filter_op/1 in query_controller.ex:187-189).
 *
 * NOTE: multiple filters on the same (field, op) collapse to the last-written
 * value because Phoenix decodes nested params into a map. Callers wanting
 * range-on-same-field must combine ops (e.g. gt + lt, which keep distinct keys).
 */
declare function buildQueryString(state: BuilderState): string;

interface BarkparkErrorOptions {
    cause?: unknown;
    requestId?: string;
    url?: string;
    status?: number;
    code?: string;
}
/**
 * Abstract base for every Barkpark error. Every subclass sets `code` to its class name,
 * so callers can match across bundle boundaries via `err.code === 'BarkparkAuthError'`
 * when `instanceof` is unreliable (pnpm hoist duplicates).
 *
 * @see ADR-009 error taxonomy.
 */
declare abstract class BarkparkError extends Error {
    readonly code: string;
    readonly requestId?: string;
    readonly url?: string;
    readonly status?: number;
    constructor(message: string, opts?: BarkparkErrorOptions);
}
interface BarkparkAPIErrorOptions extends BarkparkErrorOptions {
    body?: unknown;
}
/** Generic HTTP-API error (non-2xx with unknown/unclassified error code). Carries the raw body. */
declare class BarkparkAPIError extends BarkparkError {
    readonly body?: unknown;
    constructor(message: string, opts?: BarkparkAPIErrorOptions);
}
/** 401/403 or token invalid. Retrying won't help — caller must fix credentials. */
declare class BarkparkAuthError extends BarkparkError {
}
/** fetch() threw (DNS failure, offline, TLS). Retried only for idempotent writes. */
declare class BarkparkNetworkError extends BarkparkError {
}
interface BarkparkTimeoutErrorOptions extends BarkparkErrorOptions {
    timeoutMs?: number;
}
/** Per-attempt timeout elapsed (see config.timeoutMs). Carries the timeout value. */
declare class BarkparkTimeoutError extends BarkparkError {
    readonly timeoutMs?: number;
    constructor(message: string, opts?: BarkparkTimeoutErrorOptions);
}
interface BarkparkRateLimitErrorOptions extends BarkparkAPIErrorOptions {
    retryAfterMs?: number;
}
/** 429 response; exposes `retryAfterMs` from Retry-After header or body details. */
declare class BarkparkRateLimitError extends BarkparkAPIError {
    readonly retryAfterMs?: number;
    constructor(message: string, opts?: BarkparkRateLimitErrorOptions);
}
/** 404 (document/schema/dataset missing). `client.doc(...)` swallows this to return `null`. */
declare class BarkparkNotFoundError extends BarkparkAPIError {
}
interface BarkparkValidationErrorOptions extends BarkparkErrorOptions {
    issues?: unknown[];
    field?: string;
    reason?: string;
}
/**
 * 422 validation failure (from Phoenix changesets) OR client-side input guard
 * (e.g. patch.set on a system field). `issues` is Phoenix's `{field, message}` list.
 */
declare class BarkparkValidationError extends BarkparkError {
    readonly issues?: unknown[];
    readonly field?: string;
    readonly reason?: string;
    constructor(message: string, opts?: BarkparkValidationErrorOptions);
}
/** HMAC signature verification failed (webhook-side). Never thrown on normal client calls. */
declare class BarkparkHmacError extends BarkparkError {
}
interface BarkparkSchemaMismatchErrorOptions extends BarkparkErrorOptions {
    clientApiVersion?: string;
    serverMinApiVersion?: string;
    serverMaxApiVersion?: string;
    localSchemaHash?: string;
    remoteSchemaHash?: string;
}
/**
 * apiVersion or schema-hash drift between client and server. Caller should
 * re-run codegen or bump `apiVersion`. See ADR-007 / ADR-011.
 */
declare class BarkparkSchemaMismatchError extends BarkparkError {
    readonly clientApiVersion?: string;
    readonly serverMinApiVersion?: string;
    readonly serverMaxApiVersion?: string;
    readonly localSchemaHash?: string;
    readonly remoteSchemaHash?: string;
    constructor(message: string, opts?: BarkparkSchemaMismatchErrorOptions);
}
/** Operation not available in this edge runtime (e.g. `listen()` in Workerd). Thrown synchronously. */
declare class BarkparkEdgeRuntimeError extends BarkparkError {
}
interface BarkparkConflictErrorOptions extends BarkparkAPIErrorOptions {
    serverEtag?: string;
    serverDoc?: unknown;
}
/**
 * 409 conflict (id collision) or 412 precondition failed (ifMatch mismatch).
 * Carries `serverEtag` / `serverDoc` when available for recovery flows.
 */
declare class BarkparkConflictError extends BarkparkAPIError {
    readonly serverEtag?: string;
    readonly serverDoc?: unknown;
    constructor(message: string, opts?: BarkparkConflictErrorOptions);
}

/**
 * A {@link BarkparkClient} whose `doc`/`docs` are narrowed by a generated schema
 * `TypeMap` (type-name → document interface), so a known type returns its
 * concrete shape instead of the open {@link BarkparkDocument}.
 */
type TypedClient<TMap extends Record<string, object> = Record<string, BarkparkDocument>> = Omit<BarkparkClient, 'doc' | 'docs'> & {
    doc<K extends keyof TMap & string>(type: K, id: string): Promise<TMap[K] | null>;
    docs<K extends keyof TMap & string>(type: K): DocsBuilder<TMap[K]>;
};
/**
 * Re-type a client with a generated schema `TypeMap` so `doc`/`docs` infer the
 * concrete document interface. The runtime is the IDENTITY — only the static
 * types narrow; no behaviour changes.
 *
 * ```ts
 * import type { BarkparkTypeMap } from './barkpark.types' // emitted by `barkpark generate`
 * const bp = typedClient<BarkparkTypeMap>(createClient(cfg))
 * const post = await bp.doc('post', id) // Post | null — and bp.doc('psot', …) is a compile error
 * ```
 *
 * Pair with `@barkpark/codegen`. Without a `TypeMap` it defaults to the open
 * client shape, so calling it bare is a harmless no-op.
 */
declare function typedClient<TMap extends Record<string, object> = Record<string, BarkparkDocument>>(client: BarkparkClient): TypedClient<TMap>;

export { type ApiVersion, BarkparkAPIError, BarkparkAuthError, type BarkparkClient, type BarkparkClientConfig, BarkparkConflictError, type BarkparkDocument, BarkparkEdgeRuntimeError, BarkparkError, BarkparkHmacError, type BarkparkHooks, BarkparkNetworkError, BarkparkNotFoundError, BarkparkRateLimitError, BarkparkSchemaMismatchError, BarkparkTimeoutError, BarkparkValidationError, type BuilderState, type CommitOptions, type CreateProjectEnvelope, type CreateProjectInput, type CreateWorkspaceEnvelope, type CreateWorkspaceInput, type DocsBuilder, type FilterExpression, type FilterOp, type FilterValue, type ListProjectsEnvelope, type ListWorkspacesEnvelope, type ListenEvent, type ListenHandle, type MetaResponse, type MutateEnvelope, type MutateResult, type OrderDirection, type OrderField, type OrderSpec, type PatchBuilder, type Perspective, type Project, type QueryOptions, type ReadEnvelope, type RequestContext, type ResponseContext, type TransactionBuilder, type TypedClient, type Workspace, buildQueryString, createClient, createDocsBuilder, createDocsOperation, createHandshakeCache, createListenHandle, createPatch, createProject, createTransaction, createWorkspace, fetchRawDoc, getDoc, listProjects, listWorkspaces, makeFilterExpression, publishDoc, scopePrefix, typedClient, unpublishDoc };
