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
  type ReadEnvelope,
} from '@barkpark/core'

import {
  BarkparkLive as BarkparkLiveComponent,
  BarkparkLiveProvider as BarkparkLiveProviderComponent,
  type BarkparkLiveProps,
  type BarkparkLiveProviderProps,
} from '../client/live'

import type { BarkparkFetchOptions, BarkparkServerConfig } from './types'

import type { JSX, ReactNode } from 'react'

const VENDOR_ACCEPT = 'application/vnd.barkpark+json'

interface BuiltRequest {
  url: string
  init: RequestInit & { next?: { tags?: string[]; revalidate?: number | false } }
}

function buildUrl(cfg: BarkparkServerConfig, opts: BarkparkFetchOptions, perspective: string | undefined): string {
  const { client } = cfg
  const baseUrl = client.config.projectUrl.replace(/\/+$/, '')
  const dataset = client.config.dataset
  if (opts.id !== undefined) {
    if (opts.type === undefined || opts.type.length === 0) {
      throw new BarkparkValidationError('barkparkFetch: id requires type', { field: 'type' })
    }
    const path = `/v1/data/doc/${encodeURIComponent(dataset)}/${encodeURIComponent(opts.type)}/${encodeURIComponent(opts.id)}`
    const qs = perspective !== undefined ? `?perspective=${encodeURIComponent(perspective)}` : ''
    return `${baseUrl}${path}${qs}`
  }
  if (opts.type === undefined || opts.type.length === 0) {
    throw new BarkparkValidationError('barkparkFetch: type is required when id is not set', { field: 'type' })
  }
  const filterQs = opts.query !== undefined ? buildQueryString(opts.query) : ''
  const parts: string[] = []
  if (filterQs.length > 0) parts.push(filterQs)
  if (perspective !== undefined) parts.push(`perspective=${encodeURIComponent(perspective)}`)
  const qs = parts.length > 0 ? `?${parts.join('&')}` : ''
  return `${baseUrl}/v1/data/query/${encodeURIComponent(dataset)}/${encodeURIComponent(opts.type)}${qs}`
}

function defaultHeaders(cfg: BarkparkServerConfig, extra?: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {
    Accept: VENDOR_ACCEPT,
    'Content-Type': 'application/json',
    'Barkpark-Api-Version': cfg.client.config.apiVersion,
    ...(cfg.fetchOptions?.headers ?? {}),
    ...(extra ?? {}),
  }
  return out
}

async function decodeAndThrow(response: Response, url: string): Promise<never> {
  const status = response.status
  const requestId = response.headers.get('x-request-id') ?? undefined
  let body: unknown = undefined
  const raw = await response.text()
  if (raw.length > 0) {
    try {
      body = JSON.parse(raw)
    } catch {
      body = raw
    }
  }
  const opts: { status: number; body: unknown; url: string; requestId?: string } = { status, body, url }
  if (requestId !== undefined) opts.requestId = requestId
  if (status === 404) throw new BarkparkNotFoundError(`barkparkFetch: 404 ${url}`, opts)
  if (status === 401 || status === 403) throw new BarkparkAuthError(`barkparkFetch: ${status} ${url}`, opts)
  if (status === 429) {
    const retryAfter = response.headers.get('retry-after') ?? undefined
    const rlOpts: { status: number; body: unknown; url: string; requestId?: string; retryAfterMs?: number } = { ...opts }
    const n = retryAfter !== undefined ? Number(retryAfter) : NaN
    if (Number.isFinite(n)) rlOpts.retryAfterMs = Math.max(0, n * 1000)
    throw new BarkparkRateLimitError(`barkparkFetch: 429 ${url}`, rlOpts)
  }
  if (status >= 500) throw new BarkparkNetworkError(`barkparkFetch: ${status} ${url}`, opts)
  throw new BarkparkAPIError(`barkparkFetch: ${status} ${url}`, opts)
}

/**
 * Phase 5 v0.1 fetch helper. Branches on `draftMode()`:
 *   - !isEnabled → cache: 'force-cache' + next.tags = [bp:ds:<ds>:_all, ...userTags, ...syncTags]
 *   - isEnabled  → cache: 'no-store'   (NEVER set next.tags — Next 15.5.15 silently ignores tags
 *                  on no-store and breaks the SWR / revalidate contract; spike-c §4 / ADR-004 L31)
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

  const dataset = cfg.client.config.dataset
  const dsTag = `bp:ds:${dataset}:_all`
  const userTags = opts.tags ?? []
  const knownSyncTags = opts.syncTags ?? []

  const resolvedPerspective = isDraft ? 'drafts' : opts.perspective
  const url = buildUrl(cfg, opts, resolvedPerspective)

  return await runFetch<T>(cfg, {
    url,
    isDraft,
    userTags,
    dsTag,
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
  knownSyncTags: readonly string[]
  revalidate: number | false | undefined
  signal: AbortSignal | undefined
}

async function runFetch<T>(cfg: BarkparkServerConfig, input: RunFetchInput): Promise<T> {
  const attempt = async (token: string | undefined): Promise<Response> => {
    const headers = defaultHeaders(cfg, token !== undefined ? { Authorization: `Bearer ${token}` } : undefined)
    const init: BuiltRequest['init'] = { method: 'GET', headers }
    if (input.signal !== undefined) init.signal = input.signal
    if (input.isDraft) {
      // ADR-004 L31 / spike-c §4: MUST NOT set next.tags alongside cache:'no-store'.
      init.cache = 'no-store'
    } else {
      init.cache = 'force-cache'
      const tags: string[] = [input.dsTag, ...input.userTags, ...input.knownSyncTags]
      const nextOpts: { tags: string[]; revalidate?: number | false } = { tags }
      if (input.revalidate !== undefined) nextOpts.revalidate = input.revalidate
      init.next = nextOpts
    }
    try {
      return await fetch(input.url, init)
    } catch (e) {
      if (e instanceof Error && (e.name === 'AbortError' || e.name === 'TimeoutError')) {
        throw new BarkparkTimeoutError(`barkparkFetch: timeout ${input.url}`, { url: input.url, timeoutMs: cfg.fetchOptions?.timeout ?? 0 })
      }
      throw new BarkparkNetworkError(`barkparkFetch: network ${input.url}`, { url: input.url, cause: e })
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
      throw new BarkparkAuthError(`barkparkFetch: 401 after preview-token reissue ${input.url}`, opts)
    }
  }

  if (!resp.ok) await decodeAndThrow(resp, input.url)

  const envelope = (await resp.json()) as ReadEnvelope<T>
  return envelope.result
}

type BoundBarkparkLiveProps = Omit<BarkparkLiveProps, 'client'>
type BoundBarkparkLiveProviderProps = Omit<BarkparkLiveProviderProps, 'client'> & { children?: ReactNode }

/**
 * Inner factory — returns the per-config bundle. {@link createBarkparkServer}
 * delegates here.
 *
 * Pre-binds `BarkparkLive` / `BarkparkLiveProvider` to `cfg.client` so callers
 * don't thread `client` through each render. The pre-bound components still
 * live behind the `'use client'` boundary in `client/live.tsx`.
 *
 * @param cfg — {@link BarkparkServerConfig}; `client` + `serverToken` required.
 * @returns `{ barkparkFetch, BarkparkLive, BarkparkLiveProvider }`.
 * @throws {@link BarkparkValidationError} when `cfg` is malformed.
 *
 * @example
 * // lib/barkpark.ts — server-only
 * import 'server-only'
 * import { defineLive } from '@barkpark/nextjs/server'
 * import { client } from './barkpark-client'
 *
 * export const { barkparkFetch, BarkparkLive, BarkparkLiveProvider } =
 *   defineLive({ client, serverToken: process.env.BARKPARK_SERVER_TOKEN! })
 */
export function defineLive(cfg: BarkparkServerConfig): {
  barkparkFetch: <T>(opts?: BarkparkFetchOptions) => Promise<T>
  BarkparkLive: (props?: BoundBarkparkLiveProps) => JSX.Element | null
  BarkparkLiveProvider: (props: BoundBarkparkLiveProviderProps) => JSX.Element
} {
  validateConfig(cfg)
  const barkparkFetch = <T>(opts?: BarkparkFetchOptions) => barkparkFetchInner<T>(cfg, opts)

  // Pre-bind the underlying client component to cfg.client so consumers can render
  // <BarkparkLive /> without threading the client prop. The wrapper preserves the
  // 'use client' boundary because BarkparkLiveComponent originates from a 'use client' file.
  const BoundBarkparkLive = (props: BoundBarkparkLiveProps = {}): JSX.Element | null => {
    const merged: BarkparkLiveProps = { client: cfg.client, ...props }
    return BarkparkLiveComponent(merged)
  }
  const BoundBarkparkLiveProvider = (props: BoundBarkparkLiveProviderProps): JSX.Element => {
    return BarkparkLiveProviderComponent({ client: cfg.client, ...props })
  }

  return {
    barkparkFetch,
    BarkparkLive: BoundBarkparkLive,
    BarkparkLiveProvider: BoundBarkparkLiveProvider,
  }
}

/**
 * Top-level convenience factory. Returns `barkparkFetch` + the bound
 * `BarkparkLive` components, plus {@link defineLive} re-exposed for cases
 * where callers want to build extra per-config bundles.
 *
 * @param cfg — {@link BarkparkServerConfig}; `client` + `serverToken` required.
 * @returns `{ barkparkFetch, BarkparkLive, BarkparkLiveProvider, defineLive }`.
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
  BarkparkLive: (props?: BoundBarkparkLiveProps) => JSX.Element | null
  BarkparkLiveProvider: (props: BoundBarkparkLiveProviderProps) => JSX.Element
  defineLive: typeof defineLive
} {
  const inner = defineLive(cfg)
  return { ...inner, defineLive }
}

function validateConfig(cfg: BarkparkServerConfig): void {
  if (cfg === null || typeof cfg !== 'object') {
    throw new BarkparkValidationError('createBarkparkServer: config must be an object', { field: 'config' })
  }
  if (cfg.client === undefined || cfg.client === null || typeof cfg.client !== 'object') {
    throw new BarkparkValidationError('createBarkparkServer: client is required', { field: 'client' })
  }
  if (typeof cfg.serverToken !== 'string' || cfg.serverToken.length === 0) {
    throw new BarkparkValidationError('createBarkparkServer: serverToken must be a non-empty string', { field: 'serverToken' })
  }
}

// ---------------------------------------------------------------------------
// Direct re-exports of the real client components for `@barkpark/nextjs/server`
// consumers who'd rather use their own Provider wiring. These reference the
// 'use client' source file in src/client/live.tsx; tsup splitting plus that
// directive keeps Next's client/server boundary intact.
// ---------------------------------------------------------------------------

export {
  BarkparkLive,
  BarkparkLiveProvider,
} from '../client/live'
