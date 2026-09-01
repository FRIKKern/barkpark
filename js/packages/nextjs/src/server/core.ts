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

/**
 * Assert `value` is usable as ONE URL path segment.
 *
 * A local mirror of @barkpark/core's `assertSegment` (its `util/guards.ts`),
 * which is not on core's public export surface — the same precedent
 * {@link normalizeFieldList} below already set for a core helper this package
 * needs but cannot import. Keep the RULE identical; if core's ever lands on the
 * export surface, delete this mirror and import it.
 *
 * `encodeURIComponent` escapes `/` and `\` but NOT `.`, so an id or type of
 * `'..'` reached `fetch` intact and the WHATWG URL parser resolved it BEFORE the
 * request left: `/v1/data/doc/production/post/..` went out as
 * `/v1/data/doc/production/`, and `type: '..'` retargeted at
 * `/v1/data/doc/<id>`. Escaping harder cannot fix that — the honest rule is that
 * a path segment may not be a relative-path operator. Bounded (the api router
 * declares only `/doc/:dataset/:type/:doc_id`, so the retarget 404s — not an
 * over-broad read), but it produced a `BarkparkNotFoundError` naming a URL the
 * caller never asked for and a Next data-cache entry tagged `<prefix>:doc:..`
 * that no `revalidateTag` can ever match.
 *
 * Percent-encoded forms (`%2e%2e`) are deliberately NOT rejected, exactly as in
 * core: every value here is wrapped in `encodeURIComponent`, which escapes the
 * `%` itself (`%252e%252e`), so they can never decode back to `..` at the URL
 * parser. `/` and `\` are rejected as defence in depth — no id or type in this
 * API legitimately contains one, and the ban holds even if a future path builder
 * forgets `encodeURIComponent`.
 *
 * Takes `unknown`, not `string`: this package ships CJS/ESM to plain JS
 * consumers where no type exists, so the parameter's declared type closes
 * nothing.
 */
function assertPathSegment(value: unknown, field: string): void {
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value === '.' ||
    value === '..' ||
    /[/\\]/.test(value)
  ) {
    throw new BarkparkValidationError(
      `barkparkFetch: ${field} must be one non-empty path segment (not '.', '..', '/' or '\\')`,
      { field },
    )
  }
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
    // Both segments, before either is interpolated: a `..` in EITHER retargets
    // the fetch at an endpoint the caller never named. See assertPathSegment.
    assertPathSegment(opts.type, 'type')
    assertPathSegment(opts.id, 'id')
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
  assertPathSegment(opts.type, 'type')
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
 * Resolve the configured request deadline in milliseconds, or `undefined` for
 * "no deadline".
 *
 * Only a finite positive number arms a timer. `0` and negatives disable it (the
 * same escape hatch @barkpark/core's transport documents), and a NON-number is
 * refused rather than handed to `setTimeout` — this package ships CJS/ESM to
 * plain JS consumers, so `fetchOptions.timeout` is whatever the config object
 * actually held, and `setTimeout` coerces `'5s'` to `0`, which would abort every
 * request instantly.
 *
 * Deliberately NO invented default. Core's transport had a documented 30s/60s
 * default its code did not apply, so filling it in was a bug fix; this package
 * never documented one, and a Server Component render already has the hosting
 * platform's own limit behind it. Defaulting here would newly abort long reads
 * that work today.
 */
function resolveTimeoutMs(raw: unknown): number | undefined {
  return typeof raw === 'number' && Number.isFinite(raw) && raw > 0 ? raw : undefined
}

/** An armed request deadline, composed with any caller-supplied signal. */
interface Deadline {
  /** The signal to hand to `fetch` — the composed one, the caller's, or none. */
  readonly signal: AbortSignal | undefined
  /** True once OUR timer fired, as opposed to the caller's signal aborting. */
  fired: () => boolean
  /** Clear the timer and drop the caller-signal listener. Idempotent. */
  dispose: () => void
}

/**
 * Arm the configured deadline and compose it with a caller-supplied signal so
 * BOTH can abort the request and the winner stays attributable.
 *
 * Composition is hand-rolled on an `AbortController` — the idiom
 * @barkpark/core's transport uses — and NOT `AbortSignal.any`. Two reasons.
 * `AbortSignal.any` is declared in TypeScript's DOM lib, so `tsc --strict` would
 * not have caught its absence, while this package's `engines` field admits Node
 * 20.0.x, which predates it. And the hand-rolled form is what lets us FORWARD
 * the caller's abort `reason` onto our controller, which is precisely how
 * {@link classifyAbort} tells their deadline from ours.
 *
 * [signal-listener-leak] `{ once: true }` only self-removes if the signal
 * actually FIRES. A caller's signal routinely outlives one read — one
 * AbortController held for a whole render or job is the normal way to use this
 * API — so every request that ended any OTHER way (success, HTTP error, our own
 * timeout, a throwing decode) would leave a dead handler bound to it, and Node's
 * EventTarget starts warning past 10. {@link Deadline.dispose} runs from a
 * `finally` that every exit path unwinds through, and `removeEventListener` is
 * idempotent, so it is safe after the signal fired.
 */
function armDeadline(timeoutMs: number | undefined, caller: AbortSignal | undefined): Deadline {
  if (timeoutMs === undefined) {
    return { signal: caller, fired: () => false, dispose: () => undefined }
  }
  const ctrl = new AbortController()
  let didFire = false
  const timer = setTimeout(() => {
    didFire = true
    ctrl.abort()
  }, timeoutMs)
  let removeCallerListener: (() => void) | undefined
  if (caller !== undefined) {
    if (caller.aborted) {
      ctrl.abort(caller.reason)
    } else {
      const onCallerAbort = (): void => ctrl.abort(caller.reason)
      caller.addEventListener('abort', onCallerAbort, { once: true })
      removeCallerListener = (): void => caller.removeEventListener('abort', onCallerAbort)
    }
  }
  return {
    signal: ctrl.signal,
    fired: () => didFire,
    dispose: () => {
      clearTimeout(timer)
      removeCallerListener?.()
    },
  }
}

/**
 * Decide what an abort-shaped failure MEANS — once, for the whole request, so
 * `fetch()` rejecting and the body read rejecting get identical treatment.
 *
 * The order IS the attribution rule: report the deadline that actually fired,
 * or report none.
 *  1. OUR timer fired (and the caller's signal did not) — a
 *     {@link BarkparkTimeoutError} carrying the window that elapsed.
 *  2. The caller aborted with a plain `AbortError` — a CANCELLATION, not a
 *     timeout. Re-thrown untouched so `err.name === 'AbortError'` detection
 *     works exactly as with a bare fetch, mirroring core transport's contract.
 *     Before this, an unmount or route change cancelling a read was reported as
 *     "barkparkFetch: timeout", indistinguishable from a genuinely slow origin.
 *  3. Any other `TimeoutError`/`AbortError` — chiefly an `AbortSignal.timeout`
 *     the caller passed — IS a deadline, but THEIRS. It maps to
 *     `BarkparkTimeoutError` with NO `timeoutMs`: the configured window never
 *     elapsed, and stamping it here (as this code used to, via
 *     `cfg.fetchOptions?.timeout ?? 0`) reports a number with no relationship to
 *     the deadline that fired.
 */
function classifyAbort(e: Error, input: RunFetchInput, deadline: Deadline): Error {
  if (deadline.fired() && input.signal?.aborted !== true) {
    const opts: { url: string; cause: unknown; timeoutMs?: number } = { url: input.url, cause: e }
    if (input.timeoutMs !== undefined) opts.timeoutMs = input.timeoutMs
    return new BarkparkTimeoutError(`barkparkFetch: timeout ${input.url}`, opts)
  }
  if (input.signal?.aborted === true && e.name === 'AbortError') return e
  return new BarkparkTimeoutError(`barkparkFetch: timeout ${input.url}`, {
    url: input.url,
    cause: e,
  })
}

/** True for the two error names that mean "this request was aborted". */
function isAbortShaped(e: unknown): e is Error {
  return e instanceof Error && (e.name === 'AbortError' || e.name === 'TimeoutError')
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

/**
 * Coerce a caller-supplied cache-tag list into a real array.
 *
 * The READ-side twin of the `Array.isArray` guards on the WRITE side
 * (src/revalidate/index.ts `sync_tags` / `paths`), for the same reason and
 * against the same hazard: `opts.tags` / `opts.syncTags` are TYPED
 * `readonly string[]`, but the type closes nothing — TypeScript's
 * excess-property check fires only on a fresh object literal, and this package
 * ships CJS/ESM consumable from plain JS where no type exists at all. A bare
 * STRING is iterable, so `tags: 'my-tag'` used to SPREAD into
 * ['m','y','-','t','a','g'], and the per-element `typeof t === 'string'` filter
 * downstream is exactly what made it silent — every character passes it. The
 * fetch was then cached under six single-character junk tags and never under
 * the real one, so `revalidateTag('my-tag')` never matched: a permanently stale
 * page with no error anywhere. A non-array non-string (a number/object from a
 * config-assembled options bag) previously reached the spread and threw a raw
 * `TypeError: not iterable` out of `barkparkFetch`, escaping the Barkpark error
 * taxonomy entirely.
 *
 * COERCE rather than throw, deliberately: this is the read path, where the only
 * consequence of a caller's mistake is cache-tag shape, and a throw would turn
 * a rendering page into a 500. It also matches the two precedents this package
 * already set — {@link normalizeFieldList} above coerces `string | string[]`
 * the same way, and the write side simply IGNORES a non-array rather than
 * raising. Empty strings are dropped (an empty tag matches nothing).
 */
function asTagList(value: unknown): readonly string[] {
  if (Array.isArray(value)) return value as readonly string[]
  if (typeof value === 'string') return value.length > 0 ? [value] : []
  return []
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
  // `asTagList`, not `?? []`: a bare-string `tags` is iterable and would spread
  // character by character into the tag set below — see that helper's note.
  const userTags = asTagList(opts.tags)
  const knownSyncTags = asTagList(opts.syncTags)

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
    timeoutMs: resolveTimeoutMs(cfg.fetchOptions?.timeout),
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
  /** Configured `fetchOptions.timeout`, normalized; `undefined` = no deadline. */
  timeoutMs: number | undefined
}

/**
 * Arm the deadline, run the request, and classify every abort-shaped failure in
 * one place.
 *
 * ONE deadline covers the WHOLE call — both attempts of the draft 401-reissue
 * retry AND the body read. Core arms per-attempt because its retry policy puts
 * backoff between many attempts; here the single bounded reissue makes the
 * wall-clock reading the honest one for a Server Component render: "this read
 * will not hold the render longer than `timeout`". Keeping it armed through the
 * body is core's own scar — clearing the timer once headers arrive let a server
 * that streamed headers and then stalled the body (slow-loris) hang forever,
 * with the documented timeout never firing.
 */
async function runFetch<T>(cfg: BarkparkServerConfig, input: RunFetchInput): Promise<T> {
  const deadline = armDeadline(input.timeoutMs, input.signal)
  try {
    return await runRequest<T>(cfg, input, deadline)
  } catch (e) {
    if (isAbortShaped(e)) throw classifyAbort(e, input, deadline)
    // undici surfaces an abort that lands DURING the body stream as
    // `TypeError: terminated`, carrying the AbortError only as its `cause` — so
    // the name check above misses it and the deadline would escape as a raw
    // TypeError. Reclassify one ONLY when our own deadline actually fired and
    // the caller did not abort; every failure `decodeAndThrow` and the JSON
    // decode raise is a Barkpark* error, never a bare TypeError, so this cannot
    // swallow a real one.
    if (e instanceof TypeError && deadline.fired() && input.signal?.aborted !== true) {
      throw classifyAbort(e, input, deadline)
    }
    throw e
  } finally {
    // The ONLY place the timer and the caller-signal listener are guaranteed to
    // be dropped — every exit above unwinds through here.
    deadline.dispose()
  }
}

async function runRequest<T>(
  cfg: BarkparkServerConfig,
  input: RunFetchInput,
  deadline: Deadline,
): Promise<T> {
  const attempt = async (token: string | undefined): Promise<Response> => {
    const headers = defaultHeaders(
      cfg,
      token !== undefined ? { Authorization: `Bearer ${token}` } : undefined,
    )
    const init: BuiltRequest['init'] = { method: 'GET', headers }
    // The COMPOSED signal: the configured deadline, the caller's signal, or both.
    if (deadline.signal !== undefined) init.signal = deadline.signal
    if (input.isDraft) {
      // MUST NOT set next.tags alongside cache:'no-store': Next 15.5.15 silently
      // ignores tags on no-store, breaking revalidateTag(). See docs/decisions/0003-sync-tags.md.
      init.cache = 'no-store'
    } else {
      init.cache = 'force-cache'
      const seen = new Set<string>()
      const tags: string[] = []
      // The `typeof t === 'string'` below is an ELEMENT filter, not a container
      // guard — every character of a spread string passes it. The container
      // guard is `asTagList`, applied where userTags/knownSyncTags are built.
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
      // Abort-shaped failures are classified ONCE, in runFetch's catch — so an
      // abort that lands during the BODY read below gets the identical
      // treatment, which matters because the deadline stays armed through it.
      // Everything else is a genuine fetch-level failure (DNS/offline/TLS).
      if (isAbortShaped(e)) throw e
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

  // 304 Not Modified is a SUCCESS, not an error: it is `ok === false` with an
  // empty body (query_controller.ex emits send_resp(304, "")), so it used to
  // fall into decodeAndThrow and surface as a generic BarkparkAPIError — thrown
  // at the one caller who explicitly opted into conditional semantics. The SDK
  // never sends If-None-Match/If-Modified-Since itself and Next's data cache
  // revalidates by refetching, so a 304 is reachable ONLY when the consumer
  // injects a conditional header via cfg.fetchOptions.headers — and that caller
  // holds the copy the 304 says is still current. It joins the no-body success
  // family below (204 / empty body → undefined): undefined means "not modified,
  // keep your copy" to the only caller who can receive it.
  if (resp.status === 304) return undefined as T
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
