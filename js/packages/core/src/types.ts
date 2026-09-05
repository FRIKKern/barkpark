/**
 * Public type surface for @barkpark/core v0.1.
 * Derived from ADRs 002/005/006/007/009/010/011. Do not add shape-breaking
 * changes without an ADR amendment.
 */

import type { CreateProjectInput, CreateWorkspaceInput, Project, Workspace, Dataset } from './tenancy'
import type { ImageRef, ImageUrlOptions } from './image-url'
import type { ListenOptions } from './listen'
import type { WebhookEventKind } from './webhook'

/** YYYY-MM-DD template literal. Runtime check in createClient validates pattern. */
export type ApiVersion = `${number}-${number}-${number}`

/** Phoenix perspectives — the view a read resolves against (published docs, drafts, or raw). */
export type Perspective = 'published' | 'drafts' | 'raw'

/** Options for `client.exportDataset()` (`GET /v1/data/export/:dataset`). */
export interface ExportOptions {
  /** Restrict the export to one document type (server `?type=`). */
  type?: string
  /** Which perspective to export (server default `raw` — every stored row). */
  perspective?: Perspective
  /** AbortSignal to stop the stream early. */
  signal?: AbortSignal
}

/** System order fields (kept as literals for autocomplete). */
export type OrderField = '_updatedAt' | '_createdAt'
export type OrderDirection = 'asc' | 'desc'
// System fields keep autocomplete; `(string & {})` also admits any document
// field as `<field>:asc|desc` (e.g. 'title:asc') — query_controller.ex resolves
// it. The builder's `.order()` validates the shape at runtime.
export type OrderSpec = `${OrderField}:${OrderDirection}` | (string & {})

/**
 * The documented public filter operators, in `@valid_filter_ops` order.
 *
 * ONE OWNER, TWO LANGUAGES. `Barkpark.Content.Query.valid_filter_ops/0`
 * (api/lib/barkpark/content/query.ex) is the source of truth: it is what
 * `QueryController` derives its door from, so it IS the wire vocabulary. This
 * array is its TypeScript mirror, and the two are pinned to each other by the
 * shared fixture `api/test/fixtures/filter_ops.json` — the Elixir side asserts
 * the fixture equals `valid_filter_ops/0`
 * (api/test/barkpark/content/filter_ops_fixture_parity_test.exs) and this
 * package asserts this array equals the same fixture
 * (tests/filter-op-parity.test.ts). Neither list can move alone.
 *
 * NOT `@doc_id_only_ops` (`starts_with`, `not_starts_with`). Those are
 * builder-only spellings with clauses on the `doc_id`/`_id` column only; the
 * controller's door refuses them and `filter_ops_test.exs` pins that refusal as
 * a specification ("the door stays narrower than the builder"). Putting them
 * here would type-bless a filter every HTTP caller gets a 400 for.
 *
 * `FilterOp` is DERIVED from this array rather than hand-written beside it. A
 * union spelled separately would make the parity test compare a hand-copy to a
 * hand-copy: the runtime array could gain an op the compile-time type refused,
 * and the fixture assertion would still be green.
 *
 * `is` takes the literal string `'null'` or `'notnull'` and nothing else — it
 * is the server's IS NULL / IS NOT NULL test (`filter[<field>][is]=null`).
 * `eq`/`neq` with a `null` VALUE are sugar for the same wire form:
 * `eq(field, null)` serialises to `filter[<field>][is]=null` and
 * `neq(field, null)` to `…=notnull`, so they find documents actually missing
 * the field rather than ones equal to the empty string.
 */
export const FILTER_OPS = [
  'eq',
  'neq',
  'in',
  'nin',
  'has',
  'hasStrong',
  'contains',
  'startsWith',
  'endsWith',
  'gt',
  'gte',
  'lt',
  'lte',
  'is',
] as const

export type FilterOp = (typeof FILTER_OPS)[number]

/**
 * @internal
 *
 * This API is internal to @barkpark/core and may change without notice.
 * Use the public client API. These types describe transport internals and
 * may change. (Observability hook surfaces.)
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
  // CACHE VALIDATOR from the ETag response header (unquoted) — folds the
  // dataset schema hash, so it is NOT the write precondition. Use
  // `DocResult.etag` (the body rev) for `ifMatch`.
  etag?: string
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
  requestTagPrefix?: string // X-Barkpark-Request-Tag: <prefix>-<uuid> for observability; default 'bp', set '' to disable
  fetch?: typeof globalThis.fetch // user override (MSW, tracing)
}

/** Filter op predicates (input to fluent builder). */
export type FilterValue =
  | string
  | number
  | boolean
  | null
  | Date
  | ReadonlyArray<string | number | boolean | Date>

export interface QueryOptions {
  perspective?: Perspective
  order?: OrderSpec
  limit?: number // clamped 1..1000 server-side
  offset?: number // >= 0
  filters?: Array<{ field: string; op: FilterOp; value: FilterValue }>
}

/**
 * Filter for `client.listen()` — like a query filter but `op` is pinned to `'eq'`.
 * Real-time matching is eq-only in Phase 1A, so a non-eq op throws at runtime;
 * this type surfaces that as a compile error instead.
 */
export type ListenFilter = Array<{ field: string; op: 'eq'; value: FilterValue }>

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
  /**
   * Advisories the publish wall raised for THIS write, carried through by the
   * single-mutation helpers (`publish` / `unpublish` / `discardDraft` /
   * `patch().commit()`), which return one result rather than the envelope.
   * OMITTED — never `[]` — when the server sent none, so `'warnings' in result`
   * is a real test. Non-blocking by contract: their presence never means the
   * write failed. Batch callers read {@link MutateEnvelope.warnings} instead.
   */
  warnings?: MutateWarning[]
}

/**
 * A non-blocking advisory riding a successful mutate (the publish wall's
 * warnings channel, authoring-excellence): e.g. the 2–4 tag-count norm.
 * Advisories never block a write and are never promoted to errors.
 */
export interface MutateWarning {
  code: string
  /**
   * The emitter's own band. `'advisory'` is the default (`Warnings.put/3`);
   * the E4 dedup wall's advise band and the task plugin's merge-gate notice
   * stamp the sharper `'warning'` (dedup_wall.ex, plugins/tasks.ex). This was
   * declared as `'advisory'` alone, which made the server's real `'warning'`
   * unassignable and a `severity === 'warning'` comparison a COMPILE ERROR —
   * the SDK type was narrower than the wire. The open `(string & {})` arm keeps
   * a future band non-breaking while both known values still autocomplete.
   */
  severity: 'advisory' | 'warning' | (string & {})
  message: string
}

export interface MutateEnvelope {
  transactionId: string
  results: MutateResult[]
  /** Present only when the batch produced advisories (omitted otherwise). */
  warnings?: MutateWarning[]
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

/** A media asset returned by `client.uploadAsset()` (shape per the server's AssetResponse).
 *  Media responses key on `id` (NOT `_id`); the legacy `_id?` is kept for back-compat. */
export interface MediaAsset {
  /** Server asset id — the canonical identifier for media responses. */
  id?: string
  dataset?: string
  filename?: string
  originalName?: string
  path?: string
  originalUrl?: string
  /** Absolute (scheme + host) delivery url — the one field fetchable as-is from
   *  any origin. Server-derived from the configured CDN base, else the API's own
   *  public origin. The sibling url fields stay relative delivery paths. */
  absoluteUrl?: string
  thumbnailUrl?: string
  previewUrl?: string
  renditions?: Record<string, unknown>
  cdnUrls?: Record<string, unknown>
  mimeType?: string
  size?: number
  createdAt?: string
  updatedAt?: string
  visibility?: string
  assetDocId?: string
  url?: string
  /** Legacy id key — media responses use `id`, so this is typically undefined. */
  _id?: string
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

/**
 * Editable metadata for `client.updateAsset()` (`PATCH /v1/media/:dataset/:id`).
 * A partial patch — only the keys you pass are changed. Mirrors the server's
 * asset `@metadata_fields`; the index signature keeps it open to fields added
 * there (the response {@link MediaAsset} is likewise open).
 */
export interface UpdateAssetInput {
  title?: string
  altText?: string
  caption?: string
  description?: string
  tags?: string[]
  assetRole?: string
  rights?: string
  focalPoint?: { x: number; y: number }
  bp_visibility?: string
  [field: string]: unknown
}

/** One edge in an asset's relation graph (`client.getAssetRelations()`). */
export interface AssetRelationEdge {
  /** The relation kind (e.g. the `relatedAssets` role). */
  relation?: string
  /** The related asset's doc id. */
  assetDocId?: string
  /** The resolved related asset, when the caller may see it (else `null`). */
  asset?: MediaAsset | null
  [key: string]: unknown
}

/**
 * An asset's relation graph (`GET /v1/media/:dataset/:id/relations`).
 * `outbound` — assets this one references; `inbound` — assets that reference it
 * (where-used / impact analysis before a delete). Both are scoped to the caller.
 */
export interface AssetRelations {
  outbound: AssetRelationEdge[]
  inbound: AssetRelationEdge[]
}

/** Options for `client.searchAssets()` (`GET /v1/media/:dataset/search`). */
export interface SearchAssetsOptions {
  /** Max hits to return (server default). */
  limit?: number
  /** Hits to skip — paginate with `limit`, or use `cursor`. */
  offset?: number
  /** Opaque cursor from a prior result's `nextCursor` (keyset pagination). */
  cursor?: string
  /** Filter by MIME type (e.g. `image/png`). Sent as the `type` param. */
  mimeType?: string
  /** Filter by asset kind (image/video/…). */
  kind?: string
  /** Filter by processing/lifecycle status. */
  status?: string
  /** Restrict to a collection id. */
  collection?: string
  /** Tag filter — a comma-separated string or an array of tags. */
  tags?: string | string[]
  /** Sort order (e.g. `created-desc`, the server default). */
  sort?: string
  /** Facet dimensions to compute — a comma-separated string or an array. */
  facets?: string | string[]
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** Result of `client.searchAssets()` — media hits plus search metadata. */
export interface MediaSearchResult {
  /** The matching assets. */
  hits: MediaAsset[]
  /** Total matches (the paginator denominator). */
  total: number
  limit: number
  offset: number
  /** Facet counts per dimension, for faceted filtering UIs. */
  facets?: Record<string, unknown>
  /** Opaque cursor for the next page (keyset), or null at the end. */
  nextCursor?: string | null
  /** Whether more results exist after this page. */
  hasMore: boolean
  /** Per-hit highlight snippets, when the query produced any. */
  highlights?: Record<string, unknown>
  /** The server's parsed query (terms/filters it applied). */
  parsedQuery?: Record<string, unknown>
  /** Server-side elapsed time in ms. */
  ms?: number
  /** Opaque id for this search event — report it back to the `/search/interaction`
   *  route to record a click/quality signal against this specific query (null
   *  when the server omits it). */
  searchEventId?: string | null
}

/** One typeahead suggestion for the media search box — a prior query + its frequency. */
export interface AssetSearchSuggestion {
  query: string
  count?: number
  [key: string]: unknown
}

/**
 * Query-history suggestions for a media search box
 * (`client.getAssetSearchSuggestions()`): the caller's `recent` queries, the
 * dataset's `popular` ones, and recent `nohits` (searches that returned nothing —
 * a content-gap signal). Each bucket is filtered by the typed prefix.
 */
export interface AssetSearchSuggestions {
  recent: AssetSearchSuggestion[]
  popular: AssetSearchSuggestion[]
  nohits: AssetSearchSuggestion[]
}

/** Options for `client.getAssetSearchSuggestions()`. */
export interface AssetSearchSuggestionsOptions {
  /** Max suggestions per bucket (server default 8, max 20). */
  limit?: number
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** One typeahead suggestion for the document search box — a prior query + its frequency. */
export interface SearchSuggestion {
  query: string
  count?: number
  [key: string]: unknown
}

/**
 * Query-history suggestions for a document search box
 * (`client.getSearchSuggestions()`): the caller's `recent` queries, the dataset's
 * `popular` ones, and recent `nohits` (searches that returned nothing — a
 * content-gap signal). Each bucket is filtered by the typed prefix. The document
 * counterpart of {@link AssetSearchSuggestions}.
 */
export interface SearchSuggestions {
  recent: SearchSuggestion[]
  popular: SearchSuggestion[]
  nohits: SearchSuggestion[]
}

/** Options for `client.getSearchSuggestions()`. */
export interface SearchSuggestionsOptions {
  /** Max suggestions per bucket (server default 8, max 20). */
  limit?: number
  /**
   * Per-session identity for tokenless callers, sent as the
   * `x-bp-search-client` header — the same per-session UUID the browser UI
   * mints. Since the anonymous fail-close, header-less tokenless callers get
   * `[]` recents (they have no stable identity); pass the SAME key here and on
   * `client.search()` (the record path) to keep a safe per-session recents
   * view. Never a shared or guessable value — one UUID per user session.
   */
  sessionKey?: string
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

/** A public share link from `client.shareCollection()`. */
export interface CollectionShare {
  /** The opaque share token (embedded in `shareUrl`). */
  token: string
  /** Relative public share path (`/v1/media/:dataset/share/:token`). */
  shareUrl: string
  /** ISO-8601 expiry timestamp. */
  expiresAt: string
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

/** A node in the content graph (`client.getGraph()` / `getOrphans()`) — a document. */
export interface GraphNode {
  id?: string
  _id?: string
  _type?: string
  [key: string]: unknown
}

/** An edge in the content graph (`client.getGraph()` / `getDangling()`) — a reference. */
export interface GraphEdge {
  from_id?: string
  to_id?: string
  kind?: string
  [key: string]: unknown
}

/** Result of `client.getGraph()` — a traversal from a root document. */
export interface GraphResult {
  /** The (published-coalesced) root document id. */
  root: string
  nodes: GraphNode[]
  edges: GraphEdge[]
  /** Documents that reference into the traversed set (inbound). */
  dependents: GraphNode[]
  /** Whether the traversal hit a size/depth cap. */
  truncated: boolean
  /** Why it truncated, when `truncated` (server key, snake_case). */
  truncation_reason?: string | null
  [key: string]: unknown
}

/** Options for `client.getGraph()`. */
export interface GraphOptions {
  /** Traversal depth (clamped 1..5 server-side; default 2). */
  depth?: number
  /** `'out'` | `'in'` | `'both'` (default both). */
  direction?: 'out' | 'in' | 'both'
  /** Keep only these edge kinds. */
  kinds?: string[]
  /** Keep only these plugin_source values. */
  sources?: string[]
  /** `'published'` (default) | `'drafts'`. */
  perspective?: 'published' | 'drafts'
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** A shared tag between the source and a related candidate (`RelatedEntry.shared_tags`). */
export interface SharedTag {
  tag: string
  /** The tag's strength on the source document (0..100). */
  src_strength: number
  /** The tag's strength on the candidate document (0..100). */
  cand_strength: number
}

/** One related document from `client.getRelated()` — a fused tag-overlap / backlink candidate. */
export interface RelatedEntry {
  doc_id: string
  type: string
  /** The `documents.title` column (may be null for an untitled doc). */
  title: string | null
  /** The fused relatedness score (higher = more related). */
  score: number
  /** Which legs contributed: `'tags'` (shared tag names) and/or `'references'` (backlinks). */
  sources: Array<'tags' | 'references'>
  /** The tag names shared with the source and their per-side strengths (empty for a backlink-only match). */
  shared_tags: SharedTag[]
  [key: string]: unknown
}

/** Result of `client.getRelated()` — the ranked related documents. */
export interface RelatedResult {
  related: RelatedEntry[]
  count: number
}

/** Options for `client.getRelated()`. */
export interface RelatedOptions {
  /** Cap the fan-out (server default 10, clamped to 50). */
  limit?: number
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** One tag in the registry from `client.listTags()` — per-type published counts + a total. */
export interface TagRegistryEntry {
  tag: string
  /** Published-document count per type (e.g. `{ paper: 12, task: 3 }`). */
  counts: Record<string, number>
  /** The sum across every type. */
  total: number
}

/** Result of `client.listTags()` — the tag registry, biggest first. */
export interface ListTagsResult {
  tags: TagRegistryEntry[]
  count: number
}

/** Options for `client.listTags()`. */
export interface ListTagsOptions {
  /** Scope the corpus to these types (server default `['paper', 'task']`). */
  types?: string[]
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/** One document carrying a tag from `client.getTagDocs()`, projected with that tag's weighting. */
export interface TagDoc {
  doc_id: string
  type: string
  /** The `documents.title` column (may be null for an untitled doc). */
  title: string | null
  /** The matched (strongest) tag entry's strength — null for a legacy flat carrier. */
  strength: number | null
  /** The matched entry's rationale — null for a legacy flat carrier. */
  rationale: string | null
  /** True when this tag is the document's `main_tag`. */
  main_tag_match: boolean
  [key: string]: unknown
}

/** Result of `client.getTagDocs()` — the documents carrying a tag, ranked by its strength. */
export interface TagDocsResult {
  tag: string
  documents: TagDoc[]
  count: number
}

/** Options for `client.getTagDocs()`. */
export interface TagDocsOptions {
  /** Scope the corpus to these types (server default `['paper', 'task']`). */
  types?: string[]
  /** AbortSignal to cancel the request. */
  signal?: AbortSignal
}

/**
 * A weighted tag entry as it appears on a document's `tags` field — the wave-2
 * object shape. A legacy carrier stores a bare string instead; `normalizeTags()`
 * lifts either shape into this uniform form (a flat string → `{ tag }` only).
 */
export interface WeightedTag {
  tag: string
  /** Author-assigned strength 0..100 (absent on a legacy flat carrier). */
  strength?: number
  /** Why the tag applies (absent on a legacy flat carrier). */
  rationale?: string
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

/** Result of `client.auth.enrollMfa()` — the TOTP secret to confirm. */
export interface MfaEnrollResult {
  /** Base32 TOTP secret — pass back to `verifyMfa`. */
  secret: string
  /** `otpauth://` URI for an authenticator app / QR generator. */
  otpauth_uri: string
  /** Pre-rendered QR SVG markup for the `otpauth_uri`. */
  qr_svg: string
}

/** Result of `client.auth.verifyMfa()` — enrolment confirmed, with one-time recovery codes. */
export interface MfaVerifyResult {
  ok: boolean
  /** One-time recovery codes (TOTP fallback) — surface to the user ONCE. */
  recovery_codes: string[]
}

/** The user-auth surface, namespaced under `client.auth`. */
export interface BarkparkAuth {
  /** Register a new user (`POST /v1/auth/register`). */
  register(email: string, password: string, opts?: { signal?: AbortSignal }): Promise<AuthRegisterResult>
  /** Log in; returns `{ token, user }` (`POST /v1/auth/login`). Throws `BarkparkAuthError` (code `mfa_required` when a TOTP code is needed). */
  login(email: string, password: string, opts?: LoginOptions): Promise<AuthSession>
  /** The current user, or `null` when not authenticated (`GET /v1/auth/me`). */
  me(opts?: { signal?: AbortSignal }): Promise<AuthUser | null>
  /** Revoke the current session (`DELETE /v1/auth/logout`). */
  logout(opts?: { signal?: AbortSignal }): Promise<void>
  /** Begin TOTP MFA enrolment — re-auths with `password` (`POST /v1/auth/mfa/enroll`). */
  enrollMfa(password: string, opts?: { signal?: AbortSignal }): Promise<MfaEnrollResult>
  /** Confirm TOTP enrolment with `secret` + `code`, re-authing with `password` (`POST /v1/auth/mfa/verify`). */
  verifyMfa(
    secret: string,
    code: string,
    password: string,
    opts?: { signal?: AbortSignal },
  ): Promise<MfaVerifyResult>
  /** Disable TOTP MFA — re-auths with `password` (`POST /v1/auth/mfa/disable`). */
  disableMfa(password: string, opts?: { signal?: AbortSignal }): Promise<void>
  /** Confirm an email address with a verification token (`POST /v1/auth/verify-email`). */
  verifyEmail(token: string, opts?: { signal?: AbortSignal }): Promise<void>
  /** Request a password-reset email (`POST /v1/auth/request-reset`); always succeeds. */
  requestPasswordReset(email: string, opts?: { signal?: AbortSignal }): Promise<void>
  /**
   * Set a new password with a reset token (`POST /v1/auth/reset`); throws on a
   * bad token. Resolves with the reset receipt, whose `sessionsRevoked` is how
   * many other sessions the server killed (`null` when the server reported no
   * count at all — not the same fact as `0`).
   */
  resetPassword(
    token: string,
    password: string,
    opts?: { signal?: AbortSignal },
  ): Promise<PasswordResetReceipt>
}

/**
 * The receipt returned by a successful password reset.
 *
 * A reset revokes every OTHER session for the user; `sessionsRevoked` is the
 * count the server actually stamped, so a caller can tell the user how many
 * devices were signed out instead of guessing.
 *
 * `null` and `0` are deliberately distinct. `0` is a measurement: the server
 * counted and there were none. `null` is an absence: the server returned no
 * count (it predates the field), so nothing was measured. Collapsing `null` to
 * `0` would turn "we do not know" into "we checked and it was none", which is
 * the same unread-receipt defect the endpoint was changed to fix.
 */
export interface PasswordResetReceipt {
  sessionsRevoked: number | null
}

/**
 * The vocabulary of schema field types Barkpark understands, enumerated to match
 * the codegen mapper (`@barkpark/codegen` `mapField`). Modelled as an **open**
 * union — the `(string & {})` arm keeps any arbitrary string assignable (so this
 * is non-breaking and forward-compatible with server-added types), while the
 * literal members surface autocomplete for the known set.
 */
export type BarkparkFieldType =
  // primitives
  | 'string'
  | 'text'
  | 'color'
  | 'datetime'
  | 'number'
  | 'boolean'
  | 'slug'
  | 'image'
  // enums
  | 'select'
  | 'codelist'
  // structural
  | 'reference'
  | 'array'
  | 'arrayOf'
  | 'composite'
  | 'object'
  // special
  | 'richText'
  | 'localizedText'
  // open arm: preserves arbitrary strings so this stays non-breaking + forward-compatible
  | (string & {})

/** A content schema as serialized for the SDK (`client.schemas()` / `client.getSchema()`). */
export interface BarkparkSchema {
  id: string
  name: string
  title?: string
  visibility?: string
  schemaHash?: string
  fields: Array<{ name: string; type: BarkparkFieldType; [key: string]: unknown }>
  [key: string]: unknown
}

/** Per-type document counts within a dataset (part of {@link DatasetAnalytics}). */
export interface DocumentTypeStats {
  type: string
  /** Total documents of this type (published + drafts). */
  total: number
  published: number
  drafts: number
}

/** A single recent-activity row within {@link DatasetAnalytics.recent_activity}. */
export interface AnalyticsActivityEntry {
  id: number
  type: string
  doc_id: string
  mutation: string
  timestamp: string
  [key: string]: unknown
}

/**
 * A dataset's content-stats overview (`client.getAnalytics()`): total document
 * count, per-type published/draft breakdown, and recent activity rows. The
 * index signature keeps it open to fields the server adds.
 */
export interface DatasetAnalytics {
  dataset: string
  total_documents: number
  types: DocumentTypeStats[]
  /** Recent edit/create activity, most-recent first. */
  recent_activity: AnalyticsActivityEntry[]
  [key: string]: unknown
}

/**
 * A schema definition to register with `client.upsertSchema()`
 * (`POST /v1/schemas/:dataset`). `name` + `fields` are required; the rest are
 * optional. The server assigns `id`/`schemaHash`, so they are NOT part of the
 * input. The index signature keeps it open to any schema key the server accepts.
 */
export interface UpsertSchemaInput {
  name: string
  fields: Array<{ name: string; type: BarkparkFieldType; [key: string]: unknown }>
  title?: string
  visibility?: string
  icon?: string
  actions?: unknown[]
  [key: string]: unknown
}

/**
 * A registered outbound webhook (`client.listWebhooks()` / `getWebhook()`).
 * The `secret` is write-only — the server never echoes it back here.
 */
export interface Webhook {
  id: string
  name: string
  url: string
  dataset: string
  /** Event kinds this webhook fires on (empty = all). */
  events: WebhookEventKind[]
  /** Document types this webhook is scoped to (empty = all). */
  types: string[]
  active: boolean
  created_at?: string
  updated_at?: string
  [key: string]: unknown
}

/** Attributes for `client.createWebhook()` — `name` + `url` are required. */
export interface CreateWebhookInput {
  name: string
  url: string
  /** Event kinds to fire on (omit/empty = all). */
  events?: WebhookEventKind[]
  /** Document types to scope to (omit/empty = all). */
  types?: string[]
  /** Signing secret — signs deliveries (verify with `verifyWebhookSignature`). */
  secret?: string
  active?: boolean
  [key: string]: unknown
}

/** Attributes for `client.updateWebhook()` — a partial patch of the create input. */
export type UpdateWebhookInput = Partial<CreateWebhookInput>

/** Options for `client.search()`. */
export interface SearchOptions {
  /** Max hits to return (server default 50). */
  limit?: number
  /** Hits to skip — paginate together with `limit` (the result's `count` is the total). */
  offset?: number
  /** Restrict the search to a single document type. Mutually exclusive with `types`. */
  type?: string
  /** Restrict the search to several document types (an allowlist). Sent as the
   *  `types` CSV param; the API filters hits to `type IN (…)`. Use this for a
   *  cross-type search (`['post', 'author']`); prefer {@link SearchOptions.type}
   *  for a single type. Mutually exclusive with `type`. */
  types?: string[]
  /** Perspective override for this search; defaults to the client's `perspective`. */
  perspective?: Perspective
  /** Search engine — `postgres` (the default, always provisioned). Any other
   *  registered engine name passes through via the open string escape; an
   *  unprovisioned/unknown engine is served by Postgres and the response's
   *  `engineUsed` reports which retriever actually answered. */
  engine?: 'postgres' | (string & {})
  /**
   * Per-session identity for tokenless callers, sent as the
   * `x-bp-search-client` header. Searches are RECORDED under this key, so the
   * same value passed to `client.getSearchSuggestions()` reads them back as
   * `recent` — see {@link SearchSuggestionsOptions.sessionKey}.
   */
  sessionKey?: string
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
  correctedTo: string | null
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
  recovery?: { correctedTo?: string | null; didYouMean?: string[]; [k: string]: unknown }
  /** Whether the engine capped the result/count scan — when set, `count` is a
   *  lower bound, not exact (engine-specific; indx surfaces it, postgres omits). */
  truncation?: { truncated: boolean; scanned?: number; limit?: number; [k: string]: unknown }
  /** Which retriever ACTUALLY served this result, reported by the query
   *  pipeline — `"postgres"` even when another engine was requested but
   *  silently substituted (zero-hit recovery, unprovisioned engine). Null/
   *  absent on servers predating the field. */
  engineUsed?: string | null
  /** Server-side query latency in milliseconds. */
  ms?: number
  /** Opaque id for this search event — report it back to the `/search/interaction`
   *  route to record a click/quality signal against this specific query (null
   *  when the server omits it). */
  searchEventId?: string | null
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
  mutation?: 'create' | 'update' | 'delete' | 'publish' | 'unpublish' | 'discardDraft'
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

/** Fluent single-document patch builder. Obtain via `client.patch(id, type)` or {@link createPatch}. */
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

/**
 * A field-name argument for {@link DocsBuilder}. When `T` is a codegen'd document
 * its known keys surface as autocomplete; the `(string & {})` arm keeps arbitrary
 * strings — including dot-paths like `'price.amount'` — assignable, so widening
 * is non-breaking.
 */
export type DocFieldName<T> =
  | (keyof T & string)
  // open arm: preserves dot-paths (e.g. `price.amount`) and arbitrary field strings
  | (string & {})

/** Fluent list-query builder. Obtain via `client.docs(type)` or {@link createDocsOperation}. */
export interface DocsBuilder<T = BarkparkDocument> {
  /**
   * Add a filter (`field op value`). Supported ops per {@link FilterOp}.
   * For null/absence checks use `where(field, 'eq', null)` (→ `IS NULL`) or
   * `where(field, 'neq', null)` (→ `IS NOT NULL`) — there is no separate `is` op.
   */
  where(field: DocFieldName<T>, op: FilterOp, value: FilterValue): DocsBuilder<T>
  /** Sugar for `where(field, 'eq', value)`. */
  eq(field: DocFieldName<T>, value: string | number | boolean | Date | null): DocsBuilder<T>
  /** Sugar for `where(field, 'neq', value)` — strict `!=`; NULL/absent rows are excluded. */
  neq(field: DocFieldName<T>, value: string | number | boolean | Date | null): DocsBuilder<T>
  /** Sugar for `where(field, 'in', values)` — matches any listed value. */
  in(field: DocFieldName<T>, values: ReadonlyArray<string | number | boolean | Date>): DocsBuilder<T>
  /** Sugar for `where(field, 'nin', values)` — excludes the listed values (NULL/absent rows too). */
  nin(field: DocFieldName<T>, values: ReadonlyArray<string | number | boolean | Date>): DocsBuilder<T>
  /** Sugar for `where(field, 'has', value)` — array membership (the field's array contains `value`, as a `{_ref}` or scalar). */
  has(field: DocFieldName<T>, value: string | number | boolean | Date): DocsBuilder<T>
  /**
   * Sugar for `where(field, 'hasStrong', value)` — weighted-tag membership: matches
   * rows whose `field` array carries `<tag>` at strength ≥ `<min_strength>`. Pass the
   * scalar wire value `'<tag>:<min_strength>'` (e.g. `'search:40'`); the server splits
   * on the LAST colon, so tags containing colons are safe.
   */
  hasStrong(field: DocFieldName<T>, value: string): DocsBuilder<T>
  /** Sugar for `where(field, 'contains', value)` — substring match (case-insensitive). */
  contains(field: DocFieldName<T>, value: string): DocsBuilder<T>
  /** Sugar for `where(field, 'startsWith', value)` — prefix match (case-insensitive). */
  startsWith(field: DocFieldName<T>, value: string): DocsBuilder<T>
  /** Sugar for `where(field, 'endsWith', value)` — suffix match (case-insensitive). */
  endsWith(field: DocFieldName<T>, value: string): DocsBuilder<T>
  /** Sugar for `where(field, 'gt', value)`. */
  gt(field: DocFieldName<T>, value: string | number | Date): DocsBuilder<T>
  /** Sugar for `where(field, 'gte', value)`. */
  gte(field: DocFieldName<T>, value: string | number | Date): DocsBuilder<T>
  /** Sugar for `where(field, 'lt', value)`. */
  lt(field: DocFieldName<T>, value: string | number | Date): DocsBuilder<T>
  /** Sugar for `where(field, 'lte', value)`. */
  lte(field: DocFieldName<T>, value: string | number | Date): DocsBuilder<T>
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

/**
 * A page of query results plus the full match `total` and the server's own
 * truncation signal — returned by `findPage()`.
 */
export interface QueryPage<T = BarkparkDocument> {
  documents: T[]
  total: number
  count: number
  limit: number
  offset: number
  /**
   * Whether any row exists past this page. The SERVER'S answer, not a derived
   * one: it reads a single row beyond the page and reports whether that row
   * materialised, so it is exact and costs no COUNT.
   *
   * Read this instead of comparing `count` to `limit`. That comparison is the
   * classic wrong derivation — a type holding exactly `limit` matching rows and
   * one holding a million are byte-identical under it, and it reports "more"
   * for a page that is merely full. `offset + count < total` is correct but
   * only because `findPage` pays for a second COUNT query to know `total`.
   *
   * `false` also stands in for a server old enough not to send the field.
   */
  hasMore: boolean
  /**
   * The offset that reads the NEXT page — so a caller never re-derives it and
   * never derives one for a page with no successor. OMITTED (never `0`) when
   * `hasMore` is false, and withheld past the server's 100 000 offset ceiling,
   * where a further read would re-serve this same page rather than advance.
   */
  nextOffset?: number
}

/** Multi-mutation transaction builder. All ops commit atomically. */
export interface TransactionBuilder {
  /** Append a `create` op. The server generates the id when not provided. */
  create(doc: Partial<BarkparkDocument> & { _type: string }): TransactionBuilder
  /** Append a `createOrReplace` op — server upserts the document by `_id`. Only `_id` + `_type`
   *  are required; the server assigns `_rev` and the `_createdAt`/`_updatedAt` timestamps. */
  createOrReplace(doc: Partial<BarkparkDocument> & { _id: string; _type: string }): TransactionBuilder
  /** Append a `createIfNotExists` op — creates the document only if `_id` is free (no-op otherwise).
   *  Only `_id` + `_type` are required; the server assigns `_rev` and the timestamps. */
  createIfNotExists(doc: Partial<BarkparkDocument> & { _id: string; _type: string }): TransactionBuilder
  /** Append a `patch` op. `type` is the document's `_type` — the server requires it to
   *  dispatch the op (api-v1.md §6). Call `.set()` on the inner builder; do NOT call its
   *  `.commit()`. */
  patch(
    id: string,
    type: string,
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
    opts?: {
      expand?: string | string[]
      fields?: string | string[]
      signal?: AbortSignal
      perspective?: Perspective
    },
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
   * Pass `{ expand }` to inline reference fields, `{ fields }` to project,
   * `{ perspective }` to override the client default per-call, and/or
   * `{ signal }` (an `AbortSignal`) to cancel — the same as `doc()` / the query builder.
   */
  getDocuments<T = BarkparkDocument>(
    type: string,
    ids: string[],
    opts?: {
      expand?: string | string[]
      fields?: string | string[]
      signal?: AbortSignal
      perspective?: Perspective
    },
  ): Promise<Array<T | null>>
  /** Full-text search across the dataset (`GET /v1/data/search`). */
  search<T = BarkparkDocument>(q: string, opts?: SearchOptions): Promise<SearchResult<T>>
  /** Typeahead suggestions for a document search box — recent/popular/nohits queries
   *  (`GET /v1/data/search/:dataset/suggestions`); `prefix` filters each bucket as the user types. */
  getSearchSuggestions(
    prefix?: string,
    opts?: SearchSuggestionsOptions,
  ): Promise<SearchSuggestions>
  /** Upload a media asset (multipart `POST /v1/media/:dataset/upload`). `file` is a web `Blob`/`File`. */
  uploadAsset(file: Blob, opts?: UploadOptions): Promise<MediaAsset>
  /** List media assets in the dataset (`GET /v1/media/:dataset`). Paginate with `limit`/`offset`. */
  listAssets(opts?: ListAssetsOptions): Promise<MediaAssetPage>
  /** Fetch one media asset by id (`GET /v1/media/:dataset/:id`). Returns `null` on 404. */
  getAsset(id: string, opts?: AssetOptions): Promise<MediaAsset | null>
  /** Delete a media asset by id (`DELETE /v1/media/:dataset/:id`). Returns `{ deleted: id }`. */
  deleteAsset(id: string, opts?: AssetOptions): Promise<{ deleted: string }>
  /** Patch a media asset's metadata — alt text, caption, tags, focal point, etc.
   *  (`PATCH /v1/media/:dataset/:id`). Partial: only the passed keys change. */
  updateAsset(id: string, metadata: UpdateAssetInput, opts?: AssetOptions): Promise<MediaAsset>
  /** Check out an asset for editing (advisory lock, `POST .../:id/checkout`);
   *  throws `BarkparkConflictError` if another editor holds it. Member-only. */
  checkoutAsset(id: string, opts?: AssetOptions): Promise<MediaAsset>
  /** Release an asset's editorial lock (`POST .../:id/undo-checkout`). Member-only. */
  undoCheckoutAsset(id: string, opts?: AssetOptions): Promise<MediaAsset>
  /** An asset's relation graph — `outbound` refs + `inbound` where-used
   *  (`GET .../:id/relations`), for impact analysis before a delete. */
  getAssetRelations(id: string, opts?: AssetOptions): Promise<AssetRelations>
  /** Search the media library — full-text over asset metadata + filters
   *  (mimeType/kind/status/collection/tags) and facets (`GET .../search`).
   *  `q` may be empty for a filter-only browse. */
  searchAssets(q: string, opts?: SearchAssetsOptions): Promise<MediaSearchResult>
  /** Typeahead suggestions for a media search box — recent/popular/nohits queries
   *  (`GET .../search/suggestions`); `prefix` filters each bucket as the user types. */
  getAssetSearchSuggestions(
    prefix?: string,
    opts?: AssetSearchSuggestionsOptions,
  ): Promise<AssetSearchSuggestions>
  /** List media collections (`GET /v1/media/:dataset/collections`). Paginate with `limit`/`offset`. */
  listCollections(opts?: ListAssetsOptions): Promise<MediaCollectionPage>
  /** Fetch one media collection by id (`GET /v1/media/:dataset/collections/:id`). Returns `null` on 404. */
  getCollection(id: string, opts?: AssetOptions): Promise<MediaCollection | null>
  /** List the assets in a media collection (`GET /v1/media/:dataset/collections/:id/assets`). */
  getCollectionAssets(id: string, opts?: CollectionAssetsOptions): Promise<MediaCollectionAssets>
  /** Add an asset to a media collection (`POST .../collections/:id/members`); returns the added asset. */
  addCollectionMember(
    id: string,
    assetId: string,
    opts?: { signal?: AbortSignal },
  ): Promise<MediaAsset>
  /** Remove an asset from a media collection (`DELETE .../collections/:id/members/:assetId`); returns the removed asset. */
  removeCollectionMember(
    id: string,
    assetId: string,
    opts?: { signal?: AbortSignal },
  ): Promise<MediaAsset>
  /** Enable/rotate a collection's public share link (`POST .../collections/:id/share`); returns the token + URL + expiry. */
  shareCollection(
    id: string,
    opts?: { ttl?: number; signal?: AbortSignal },
  ): Promise<CollectionShare>
  /** Revoke a collection's public share link (`DELETE .../collections/:id/share`). */
  revokeCollectionShare(id: string, opts?: { signal?: AbortSignal }): Promise<void>
  /** Documents that reference `id` — inbound references / backlinks (`GET /v1/data/backlinks/:dataset/:id`). */
  getBacklinks(id: string, opts?: BacklinksOptions): Promise<BacklinksResult>
  /** Documents related to `id` — tag-overlap fused with backlinks (`GET /v1/data/related/:dataset/:id`). */
  getRelated(id: string, opts?: RelatedOptions): Promise<RelatedResult>
  /** Browse the tag registry — per-tag per-type published counts (`GET /v1/data/tags/:dataset`). */
  listTags(opts?: ListTagsOptions): Promise<ListTagsResult>
  /** Documents carrying `tag`, ranked by that tag's strength (`GET /v1/data/tags/:dataset/:tag`). */
  getTagDocs(tag: string, opts?: TagDocsOptions): Promise<TagDocsResult>
  /** Traverse the content graph from a root document (`GET /v1/graph/:id`). */
  getGraph(id: string, opts?: GraphOptions): Promise<GraphResult>
  /** Documents with zero edges — orphans (`GET /v1/graph/orphans`). */
  getOrphans(opts?: { signal?: AbortSignal }): Promise<GraphNode[]>
  /** Broken references — edges whose target is unresolvable (`GET /v1/graph/dangling`). */
  getDangling(opts?: { signal?: AbortSignal }): Promise<GraphEdge[]>
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
   * otherwise the original. `baseUrl` defaults to the client's `projectUrl`. Workspace/
   * project-scoped clients emit `/w/<ws>/p/<proj>`-prefixed rendition (and `/images/`)
   * URLs — the flat route is pinned to the Default workspace, so scoped renditions are
   * only reachable via the scoped route.
   */
  imageUrl(asset: ImageRef | null | undefined, opts?: ImageUrlOptions): string | null
  /** List all content schemas in the dataset (`GET /v1/schemas`) — for dynamic/generic UIs. */
  schemas(opts?: { signal?: AbortSignal }): Promise<BarkparkSchema[]>
  /** Fetch one schema by type name, or `null` if it doesn't exist. */
  getSchema(name: string, opts?: { signal?: AbortSignal }): Promise<BarkparkSchema | null>
  /** Register (create or replace) a content-type schema (`POST /v1/schemas/:dataset`).
   *  Idempotent upsert; throws `BarkparkValidationError` on an invalid definition. */
  upsertSchema(schema: UpsertSchemaInput): Promise<BarkparkSchema>
  /** Delete a content-type schema by name (`DELETE /v1/schemas/:dataset/:name`). */
  deleteSchema(name: string): Promise<{ deleted: string }>
  /** Fetch the dataset's content-stats overview (`GET /v1/data/analytics/:dataset`):
   *  total documents, per-type published/draft counts, and recent activity. */
  getAnalytics(opts?: { signal?: AbortSignal }): Promise<DatasetAnalytics>
  /** List the dataset's registered outbound webhooks (`GET /v1/webhooks/:dataset`). */
  listWebhooks(opts?: { signal?: AbortSignal }): Promise<Webhook[]>
  /** Fetch one webhook by id, or `null` if it doesn't exist. */
  getWebhook(id: string, opts?: { signal?: AbortSignal }): Promise<Webhook | null>
  /** Register a webhook (`POST /v1/webhooks/:dataset`). `name` + `url` required. */
  createWebhook(input: CreateWebhookInput, opts?: { signal?: AbortSignal }): Promise<Webhook>
  /** Update a webhook (`PUT /v1/webhooks/:dataset/:id`). */
  updateWebhook(
    id: string,
    input: UpdateWebhookInput,
    opts?: { signal?: AbortSignal },
  ): Promise<Webhook>
  /** Delete a webhook by id (`DELETE /v1/webhooks/:dataset/:id`). Returns `{ deleted }`. */
  deleteWebhook(id: string, opts?: { signal?: AbortSignal }): Promise<{ deleted: string }>
  /** Open a single-doc patch builder. `type` is the document's `_type`, which the server
   *  requires on every patch op (api-v1.md §6). */
  patch(id: string, type: string): PatchBuilder
  /** Open a multi-op transaction builder. */
  transaction(): TransactionBuilder
  /** Create one document — convenience for `transaction().create(doc).commit(opts)`.
   *  `opts` forwards to the commit (retry / idempotencyKey / timeoutMs). */
  create(
    doc: Partial<BarkparkDocument> & { _type: string },
    opts?: CommitOptions,
  ): Promise<MutateEnvelope>
  /** Create or replace one document by `_id` — single-op transaction convenience. Only `_id` +
   *  `_type` are required; the server assigns `_rev` and the `_createdAt`/`_updatedAt` timestamps. */
  createOrReplace(
    doc: Partial<BarkparkDocument> & { _id: string; _type: string },
    opts?: CommitOptions,
  ): Promise<MutateEnvelope>
  /** Create one document only if its `_id` is free (no-op otherwise) — single-op convenience.
   *  Only `_id` + `_type` are required; the server assigns `_rev` and the timestamps. */
  createIfNotExists(
    doc: Partial<BarkparkDocument> & { _id: string; _type: string },
    opts?: CommitOptions,
  ): Promise<MutateEnvelope>
  /** Delete one document by id + type — single-op convenience. `opts.ifMatch` guards the
   *  rev; retry / idempotencyKey / timeoutMs forward to the commit. */
  delete(id: string, type: string, opts?: CommitOptions): Promise<MutateEnvelope>
  /** Publish a draft. `opts` forwards retry / idempotencyKey / timeoutMs to the write. */
  publish(id: string, type: string, opts?: CommitOptions): Promise<MutateResult>
  /** Unpublish (move back to draft). `opts` forwards retry / idempotencyKey / timeoutMs. */
  unpublish(id: string, type: string, opts?: CommitOptions): Promise<MutateResult>
  /** Discard a draft's unsaved edits — drops `drafts.{id}`, leaving the published `{id}`.
   *  `opts` forwards retry / idempotencyKey / timeoutMs to the write. */
  discardDraft(id: string, type: string, opts?: CommitOptions): Promise<MutateResult>
  /** Open an SSE live-stream. Throws {@link BarkparkEdgeRuntimeError} in Workerd. */
  listen<T = BarkparkDocument>(type?: string, filter?: ListenFilter, opts?: ListenOptions): ListenHandle<T>
  /** Stream a dataset's documents as NDJSON (`GET /v1/data/export/:dataset`) —
   *  the backup/portability export, yielded lazily via an async iterable. */
  exportDataset(opts?: ExportOptions): AsyncGenerator<BarkparkDocument, void, unknown>
  /** Escape hatch for arbitrary paths. Returns the raw `Response` (NOT parsed JSON, NOT envelope-decoded) — call `.json()`/`.text()` yourself. A type argument asserts the shape of the body you will read; it does not change the runtime value. */
  fetchRaw<T = Response>(path: string, init?: RequestInit): Promise<T>
  /**
   * List the workspaces the token can reach. Calls the top-level tenancy
   * endpoint `GET /api/workspaces` — not dataset-scoped, not scopePrefix-prefixed.
   */
  listWorkspaces(opts?: { signal?: AbortSignal }): Promise<Workspace[]>
  /**
   * List the projects under a workspace via `GET /api/workspaces/:slug/projects`.
   * Top-level tenancy endpoint — independent of the client's workspace/project scope.
   */
  listProjects(workspaceSlug: string, opts?: { signal?: AbortSignal }): Promise<Project[]>
  /**
   * List the datasets under a project via
   * `GET /api/workspaces/:ws/projects/:proj/datasets` — completes the tenancy
   * drill-down (workspaces → projects → datasets). Top-level tenancy endpoint.
   */
  listDatasets(
    workspaceSlug: string,
    projectSlug: string,
    opts?: { signal?: AbortSignal },
  ): Promise<Dataset[]>
  /**
   * Create a workspace via `POST /api/workspaces` with `{ name, slug? }`. Returns the
   * created workspace. Top-level tenancy endpoint — token-authed, not dataset-scoped.
   */
  createWorkspace(attrs: CreateWorkspaceInput, opts?: { signal?: AbortSignal }): Promise<Workspace>
  /**
   * Create a project under a workspace via `POST /api/workspaces/:slug/projects` with
   * `{ name, slug? }`. Returns the created project. Top-level tenancy endpoint — token-authed.
   */
  createProject(
    workspaceSlug: string,
    attrs: CreateProjectInput,
    opts?: { signal?: AbortSignal },
  ): Promise<Project>
}
