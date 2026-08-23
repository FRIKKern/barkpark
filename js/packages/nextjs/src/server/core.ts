// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import 'server-only'

import { draftMode } from 'next/headers'
import {
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkNetworkError,
  BarkparkNotFoundError,
  BarkparkRateLimitError,
  BarkparkTimeoutError,
  BarkparkValidationError,
  buildQueryString,
  scopePrefix,
} from '@barkpark/core'

import type { BarkparkFetchOptions, BarkparkServerConfig } from './types'
import { formatTagPrefix } from '../tag-prefix'

const VENDOR_ACCEPT = 'application/vnd.barkpark+json'

interface BuiltRequest {
  url: string
  init: RequestInit & { next?: { tags?: string[]; revalidate?: number | false } }
}

/**
 * Resolve the workspace/project scope prefix for this server config. The server
 * config's `workspace`/`project` (when set) take precedence over the client's
 * `client.config` values; both must resolve before `scopePrefix` emits a prefix.
 * Returns `/w/<ws>/p/<project>` when scoped, `''` for the flat `/v1/...` routes
 * (back-compat).
 */
function resolveScopePrefix(cfg: BarkparkServerConfig): string {
  const clientConfig = cfg.client.config
  // Spread first, then only assign workspace/project when a value resolves —
  // under exactOptionalPropertyTypes we must not write `undefined` onto an
  // optional `string` field. Server-config values take precedence over the client's.
  const resolved = { ...clientConfig }
  const workspace = cfg.workspace ?? clientConfig.workspace
  const project = cfg.project ?? clientConfig.project
  if (workspace !== undefined) resolved.workspace = workspace
  else delete resolved.workspace
  if (project !== undefined) resolved.project = project
  else delete resolved.project
  return scopePrefix(resolved)
}

/**
 * Build the cache-tag namespace prefix for this server config. Mirrors how
 * {@link resolveScopePrefix} resolves workspace/project (server-config value
 * takes precedence over the client's). When BOTH a workspace and a project
 * resolve, returns the SCOPED `bp:ws:<ws>:p:<project>:ds:<dataset>` prefix —
 * the exact grammar the s15 revalidate ingestion parses — so generated tags
 * round-trip with webhook-driven invalidation. Otherwise returns the LEGACY
 * flat `bp:ds:<dataset>` prefix (back-compat).
 */
function resolveTagPrefix(cfg: BarkparkServerConfig): string {
  const clientConfig = cfg.client.config
  // Format via the shared source of truth — keeps read tags identical to the
  // write side (defineActions) and the webhook revalidate fallback.
  return formatTagPrefix(
    clientConfig.dataset,
    cfg.workspace ?? clientConfig.workspace,
    cfg.project ?? clientConfig.project,
  )
}

function buildUrl(
  cfg: BarkparkServerConfig,
  opts: BarkparkFetchOptions,
  perspective: string | undefined,
): string {
  const { client } = cfg
  const baseUrl = client.config.projectUrl.replace(/\/+$/, '')
  const scope = resolveScopePrefix(cfg)
  const dataset = client.config.dataset
  if (opts.id !== undefined) {
    if (opts.type === undefined || opts.type.length === 0) {
      throw new BarkparkValidationError('barkparkFetch: id requires type', { field: 'type' })
    }
    const path = `/v1/data/doc/${encodeURIComponent(dataset)}/${encodeURIComponent(opts.type)}/${encodeURIComponent(opts.id)}`
    // Single-doc fetch supports expand (inline refs) + fields (projection), same as
    // `bp.doc(id, { expand, fields })` — the /doc endpoint honors both.
    const idParts: string[] = []
    if (perspective !== undefined) idParts.push(`perspective=${encodeURIComponent(perspective)}`)
    // Fail closed exactly like core getDoc (normalizeFieldList): comma-in-name
    // and empty-list are caller bugs, not params to silently mangle or omit.
    if (opts.expand !== undefined) {
      idParts.push(`expand=${encodeURIComponent(normalizeFieldList(opts.expand, 'expand'))}`)
    }
    if (opts.fields !== undefined) {
      idParts.push(`fields=${encodeURIComponent(normalizeFieldList(opts.fields, 'fields'))}`)
    }
    const qs = idParts.length > 0 ? `?${idParts.join('&')}` : ''
    return `${baseUrl}${scope}${path}${qs}`
  }
  if (opts.type === undefined || opts.type.length === 0) {
    throw new BarkparkValidationError('barkparkFetch: type is required when id is not set', {
      field: 'type',
    })
  }
  const filterQs = opts.query !== undefined ? buildQueryString(opts.query) : ''
  const parts: string[] = []
  if (filterQs.length > 0) parts.push(filterQs)
  if (perspective !== undefined) parts.push(`perspective=${encodeURIComponent(perspective)}`)
  const qs = parts.length > 0 ? `?${parts.join('&')}` : ''
  return `${baseUrl}${scope}/v1/data/query/${encodeURIComponent(dataset)}/${encodeURIComponent(opts.type)}${qs}`
}

function defaultHeaders(
  cfg: BarkparkServerConfig,
  extra?: Record<string, string>,
): Record<string, string> {
  const out: Record<string, string> = {
    Accept: VENDOR_ACCEPT,
    'Content-Type': 'application/json',
    'Barkpark-Api-Version': cfg.client.config.apiVersion,
    ...(cfg.fetchOptions?.headers ?? {}),
    ...(extra ?? {}),
  }
  return out
}

function strOrUndefined(v: unknown): string | undefined {
  return typeof v === 'string' && v.length > 0 ? v : undefined
}

/**
 * Normalize an expand/fields list into the comma-joined query-param value the
 * server expects — a local mirror of core's `normalizeFieldList`
 * (js/packages/core/src/filter-builder.ts), which is not on core's public
 * export surface (the @barkpark/core bundle sits bytes under its size cap, so
 * widening its index for this helper was not worth the risk). Same contract:
 * trim, drop empties, throw on an empty result or a comma inside a name (a
 * comma would silently split into extra projected/expanded fields — an
 * over-broad read). If core ever exports it, delete this mirror and import.
 */
function normalizeFieldList(input: string | readonly string[], label: string): string {
  const list = Array.isArray(input) ? input : [input]
  const cleaned = list.map((f) => String(f).trim()).filter((f) => f.length > 0)
  if (cleaned.length === 0) {
    throw new BarkparkValidationError(`${label} requires at least one field name`, { field: label })
  }
  const bad = cleaned.find((f) => f.includes(','))
  if (bad !== undefined) {
    throw new BarkparkValidationError(
      `${label} field name cannot contain a comma: ${JSON.stringify(bad)} (pass separate fields as an array)`,
      { field: label },
    )
  }
  return cleaned.join(',')
}

function pickRequestId(body: unknown): string | undefined {
  if (body === null || typeof body !== 'object') return undefined
  const b = body as Record<string, unknown>
  return strOrUndefined(b['request_id']) ?? strOrUndefined(b['requestId'])
}

/**
 * Decode a non-2xx Response into the right {@link BarkparkError} subclass,
 * mirroring core's `decodeErrorAndThrow` (js/packages/core/src/transport.ts):
 * extracts `code`/`message`/`hint`/`request_id` from the canonical
 * `{error:{...}}` envelope (falling back to a bare string-valued `error`), sets
 * `serverCode`+`hint` on every thrown error, maps 5xx to the generic
 * `BarkparkAPIError` (NOT `BarkparkNetworkError`, which is reserved for
 * `fetch()` itself throwing — see errors.ts), and maps 422 to
 * `BarkparkValidationError` with `issues` built from the envelope's `details`
 * field→message map.
 */
async function decodeAndThrow(response: Response, url: string): Promise<never> {
  const status = response.status
  const requestIdHeader = response.headers.get('x-request-id') ?? undefined
  const raw = await response.text()

  let parsed: unknown = undefined
  if (raw.length > 0) {
    try {
      parsed = JSON.parse(raw)
    } catch {
      const apiOpts: { status: number; body: unknown; url: string; requestId?: string } = {
        status,
        body: raw,
        url,
      }
      if (requestIdHeader !== undefined) apiOpts.requestId = requestIdHeader
      throw new BarkparkAPIError(`barkparkFetch: unexpected non-JSON response ${url}`, apiOpts)
    }
  }

  const errorField =
    parsed !== null && typeof parsed === 'object' && 'error' in parsed
      ? (parsed as { error?: unknown }).error
      : undefined

  // Canonical envelope: `error` is an object ({code, message, request_id, hint}).
  const envelope =
    typeof errorField === 'object' && errorField !== null
      ? (errorField as Record<string, unknown>)
      : undefined

  // Bare string-valued `error` (e.g. {"error":"not_found"} from legacy/admin
  // endpoints) — the string is the machine `code`; the message unless a
  // sibling `reason` is present.
  const bareCode = strOrUndefined(errorField)
  const bareReason =
    parsed !== null && typeof parsed === 'object'
      ? strOrUndefined((parsed as { reason?: unknown }).reason)
      : undefined

  const code = envelope ? strOrUndefined(envelope['code']) : bareCode
  const message =
    (envelope ? strOrUndefined(envelope['message']) : (bareReason ?? bareCode)) ??
    `barkparkFetch: ${status} ${url}`
  const requestId = pickRequestId(envelope) ?? requestIdHeader
  const hint = envelope ? strOrUndefined(envelope['hint']) : undefined
  // `!== null` is load-bearing: typeof null === 'object', so without it a
  // `details: null` envelope (a normal Phoenix changeset-less 422) sets
  // details = null, and Object.entries(details) below would throw a raw
  // TypeError that escapes the error taxonomy.
  const details =
    envelope && typeof envelope['details'] === 'object' && envelope['details'] !== null
      ? (envelope['details'] as Record<string, unknown>)
      : undefined

  const base: {
    status: number
    body: unknown
    url: string
    requestId?: string
    hint?: string
    serverCode?: string
  } = { status, body: parsed, url }
  if (requestId !== undefined) base.requestId = requestId
  if (hint !== undefined) base.hint = hint
  if (code !== undefined) base.serverCode = code

  if (status === 404) throw new BarkparkNotFoundError(message, base)
  if (status === 401 || status === 403) throw new BarkparkAuthError(message, base)
  if (status === 429) {
    const retryAfter = response.headers.get('retry-after') ?? undefined
    const rlOpts: typeof base & { retryAfterMs?: number } = { ...base }
    const n = retryAfter !== undefined ? Number(retryAfter) : NaN
    if (Number.isFinite(n)) rlOpts.retryAfterMs = Math.max(0, n * 1000)
    throw new BarkparkRateLimitError(message, rlOpts)
  }
  // 422 / validation_failed — Phoenix `details` is a field->[msg] map.
  if (status === 422) {
    const opts: typeof base & { issues?: unknown[] } = { ...base }
    if (details !== undefined) {
      const issues: unknown[] = []
      for (const [field, msgs] of Object.entries(details)) {
        if (Array.isArray(msgs)) {
          for (const m of msgs) issues.push({ field, message: m })
        } else {
          issues.push({ field, message: msgs })
        }
      }
      if (issues.length > 0) opts.issues = issues
    }
    throw new BarkparkValidationError(message, opts)
  }
  // Everything else (including 5xx) -> generic API error with body + status.
  // 5xx is a real HTTP response from the server, not a `fetch()` failure, so
  // it does NOT map to BarkparkNetworkError (reserved for DNS/offline/TLS —
  // see errors.ts).
  throw new BarkparkAPIError(message, base)
}

/**
 * Phase 5 v0.1 fetch helper. Branches on `draftMode()`:
 *   - !isEnabled → cache: 'force-cache' + next.tags = [bp:ds:<ds>:_all, ...userTags, ...syncTags]
 *   - isEnabled  → cache: 'no-store'   (NEVER set next.tags — Next 15.5.15 silently ignores tags
 *                  on no-store and breaks the SWR / revalidate contract; docs/decisions/0003-sync-tags.md)
 *                + perspective=drafts query param + Authorization: Bearer ${serverToken}
 *
 * On draft 401: one auto-reissue attempt (calls cfg.reissuePreviewToken if provided), then retries.
 * Second 401 throws BarkparkAuthError.
 *
 * syncTags: in v0.1 we don't issue a second pre-fetch to learn syncTags; callers may pass them
 * via opts.syncTags when warmed by preloadDocument (Wave 4 I3, React cache()).
 */
export async function barkparkFetchInner<T = unknown>(
  cfg: BarkparkServerConfig,
  opts: BarkparkFetchOptions = {},
): Promise<T> {
  const dm = await draftMode()
  const isDraft = dm.isEnabled === true

  // Namespace prefix: SCOPED `bp:ws:<ws>:p:<project>:ds:<dataset>` when
  // workspace+project are configured (matches the s15 revalidate ingest
  // grammar), else LEGACY flat `bp:ds:<dataset>` (back-compat).
  const prefix = resolveTagPrefix(cfg)
  const dsTag = `${prefix}:_all`
  const userTags = opts.tags ?? []
  const knownSyncTags = opts.syncTags ?? []

  // Canonical auto-tags so `revalidateTag('<prefix>:doc:<id>')` and
  // `:type:<type>` fired by the webhook bridge actually match this fetch.
  // Order: [dsTag, typeTag?, docTag?, ...userTags, ...knownSyncTags]
  // — userTags trail the canonical set so caller-provided tags still win
  // ordering for user-visible assertions.
  const autoTags: string[] = []
  if (typeof opts.type === 'string' && opts.type.length > 0) {
    autoTags.push(`${prefix}:type:${opts.type}`)
    if (typeof opts.id === 'string' && opts.id.length > 0) {
      autoTags.push(`${prefix}:doc:${opts.id}`)
    }
  }

  const resolvedPerspective = isDraft ? 'drafts' : opts.perspective
  const url = buildUrl(cfg, opts, resolvedPerspective)

  return await runFetch<T>(cfg, {
    url,
    isDraft,
    userTags,
    dsTag,
    autoTags,
    knownSyncTags,
    revalidate: opts.revalidate,
    signal: opts.signal ?? cfg.fetchOptions?.signal,
  })
}

interface RunFetchInput {
  url: string
  isDraft: boolean
  userTags: readonly string[]
  dsTag: string
  autoTags: readonly string[]
  knownSyncTags: readonly string[]
  revalidate: number | false | undefined
  signal: AbortSignal | undefined
}

async function runFetch<T>(cfg: BarkparkServerConfig, input: RunFetchInput): Promise<T> {
  const attempt = async (token: string | undefined): Promise<Response> => {
    const headers = defaultHeaders(
      cfg,
      token !== undefined ? { Authorization: `Bearer ${token}` } : undefined,
    )
    const init: BuiltRequest['init'] = { method: 'GET', headers }
    if (input.signal !== undefined) init.signal = input.signal
    if (input.isDraft) {
      // MUST NOT set next.tags alongside cache:'no-store': Next 15.5.15 silently
      // ignores tags on no-store, breaking revalidateTag(). See docs/decisions/0003-sync-tags.md.
      init.cache = 'no-store'
    } else {
      init.cache = 'force-cache'
      const seen = new Set<string>()
      const tags: string[] = []
      for (const t of [input.dsTag, ...input.autoTags, ...input.userTags, ...input.knownSyncTags]) {
        if (typeof t === 'string' && t.length > 0 && !seen.has(t)) {
          seen.add(t)
          tags.push(t)
        }
      }
      const nextOpts: { tags: string[]; revalidate?: number | false } = { tags }
      if (input.revalidate !== undefined) nextOpts.revalidate = input.revalidate
      init.next = nextOpts
    }
    try {
      return await fetch(input.url, init)
    } catch (e) {
      // A caller-initiated abort is a CANCELLATION, not a timeout: re-throw the
      // AbortError untouched so callers detect it via `err.name === 'AbortError'`
      // exactly as with a bare fetch — mirroring core transport's contract
      // (js/packages/core/src/transport.ts). Before this guard, an unmount or
      // route change cancelling a read was reported as "barkparkFetch: timeout",
      // indistinguishable from a genuinely slow origin. A TimeoutError (e.g.
      // from an AbortSignal.timeout the caller passed) IS a deadline and still
      // maps to BarkparkTimeoutError below.
      if (input.signal?.aborted === true && e instanceof Error && e.name === 'AbortError') {
        throw e
      }
      if (e instanceof Error && (e.name === 'AbortError' || e.name === 'TimeoutError')) {
        throw new BarkparkTimeoutError(`barkparkFetch: timeout ${input.url}`, {
          url: input.url,
          timeoutMs: cfg.fetchOptions?.timeout ?? 0,
        })
      }
      throw new BarkparkNetworkError(`barkparkFetch: network ${input.url}`, {
        url: input.url,
        cause: e,
      })
    }
  }

  const draftToken = input.isDraft ? cfg.serverToken : undefined
  let resp = await attempt(draftToken)

  if (input.isDraft && resp.status === 401) {
    const fresh = cfg.reissuePreviewToken ? await cfg.reissuePreviewToken() : cfg.serverToken
    resp = await attempt(fresh)
    if (resp.status === 401) {
      const opts: { status: number; body: unknown; url: string; requestId?: string } = {
        status: 401,
        body: undefined,
        url: input.url,
      }
      const requestId = resp.headers.get('x-request-id') ?? undefined
      if (requestId !== undefined) opts.requestId = requestId
      throw new BarkparkAuthError(
        `barkparkFetch: 401 after preview-token reissue ${input.url}`,
        opts,
      )
    }
  }

  if (!resp.ok) await decodeAndThrow(resp, input.url)

  // Ok-path body decode — mirror core transport (js/packages/core/src/transport.ts
  // ok-path): a 204 or an empty/non-JSON 2xx body must NOT reach resp.json(), which
  // would throw a raw SyntaxError that escapes the Barkpark error taxonomy. 204 and
  // empty bodies resolve to undefined (core treats them as success); a non-JSON body
  // throws BarkparkAPIError so callers filtering on `instanceof BarkparkError` catch it.
  if (resp.status === 204) return undefined as T
  const text = await resp.text()
  if (text.length === 0) return undefined as T
  try {
    return JSON.parse(text) as T
  } catch (err) {
    throw new BarkparkAPIError(`barkparkFetch: unexpected non-JSON response ${input.url}`, {
      status: resp.status,
      body: text,
      url: input.url,
      cause: err,
    })
  }
}

/**
 * Inner factory — returns the per-config bundle. {@link createBarkparkServer}
 * delegates here.
 *
 * Returns only the server-safe `barkparkFetch` bound to `cfg`. `BarkparkLive` /
 * `BarkparkLiveProvider` are intentionally NOT returned here: importing the
 * client component module from the server graph would pull `React.createContext`
 * into a `react-server` context (Next 15 RSC), which crashes with
 * `TypeError: (0, react.createContext) is not a function`. Import them directly
 * from `@barkpark/nextjs/client` instead, and thread `cfg.client` as a prop.
 *
 * @param cfg — {@link BarkparkServerConfig}; `client` + `serverToken` required.
 * @returns `{ barkparkFetch }`.
 * @throws {@link BarkparkValidationError} when `cfg` is malformed.
 *
 * @example
 * // lib/barkpark.ts — server-only
 * import 'server-only'
 * import { defineLive } from '@barkpark/nextjs/server'
 * import { client } from './barkpark-client'
 *
 * export const { barkparkFetch } =
 *   defineLive({ client, serverToken: process.env.BARKPARK_SERVER_TOKEN! })
 *
 * // In a client component:
 * // import { BarkparkLive, BarkparkLiveProvider } from '@barkpark/nextjs/client'
 */
export function defineLive(cfg: BarkparkServerConfig): {
  barkparkFetch: <T>(opts?: BarkparkFetchOptions) => Promise<T>
} {
  validateConfig(cfg)
  const barkparkFetch = <T>(opts?: BarkparkFetchOptions) => barkparkFetchInner<T>(cfg, opts)
  return { barkparkFetch }
}

/**
 * Top-level convenience factory. Returns `barkparkFetch` plus {@link defineLive}
 * re-exposed for callers who want to build extra per-config bundles.
 *
 * `BarkparkLive` / `BarkparkLiveProvider` are intentionally NOT returned —
 * import them from `@barkpark/nextjs/client` to keep the server graph free of
 * `React.createContext` under Next 15's `react-server` condition.
 *
 * @param cfg — {@link BarkparkServerConfig}; `client` + `serverToken` required.
 * @returns `{ barkparkFetch, defineLive }`.
 * @throws {@link BarkparkValidationError} when `cfg` is malformed.
 *
 * @example
 * // lib/barkpark.ts
 * import 'server-only'
 * import { createBarkparkServer } from '@barkpark/nextjs/server'
 * import { client } from './barkpark-client'
 *
 * export const server = createBarkparkServer({
 *   client,
 *   serverToken: process.env.BARKPARK_SERVER_TOKEN!,
 * })
 *
 * // app/page.tsx
 * export default async function Page() {
 *   const posts = await server.barkparkFetch({ type: 'post' })
 *   return <PostList posts={posts} />
 * }
 */
export function createBarkparkServer(cfg: BarkparkServerConfig): {
  barkparkFetch: <T>(opts?: BarkparkFetchOptions) => Promise<T>
  defineLive: typeof defineLive
} {
  const inner = defineLive(cfg)
  return { ...inner, defineLive }
}

function validateConfig(cfg: BarkparkServerConfig): void {
  if (cfg === null || typeof cfg !== 'object') {
    throw new BarkparkValidationError('createBarkparkServer: config must be an object', {
      field: 'config',
    })
  }
  if (cfg.client === undefined || cfg.client === null || typeof cfg.client !== 'object') {
    throw new BarkparkValidationError('createBarkparkServer: client is required', {
      field: 'client',
    })
  }
  if (typeof cfg.serverToken !== 'string' || cfg.serverToken.length === 0) {
    throw new BarkparkValidationError(
      'createBarkparkServer: serverToken must be a non-empty string',
      { field: 'serverToken' },
    )
  }
}

// ---------------------------------------------------------------------------
// BarkparkLive / BarkparkLiveProvider are NOT re-exported from the server entry.
// They live in a `'use client'` module (`src/client/live.tsx`) and would pull
// `React.createContext` into the Next 15 `react-server` graph if imported here.
// Consumers: `import { BarkparkLive, BarkparkLiveProvider } from '@barkpark/nextjs/client'`.
// ---------------------------------------------------------------------------
