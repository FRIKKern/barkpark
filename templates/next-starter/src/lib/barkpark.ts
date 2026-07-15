// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Server-only Barkpark content link for the Next.js node-slot starter. Unlike
// the astro-starter (which fetches at BUILD time and emits static HTML), this
// module runs at REQUEST time inside the long-lived Node SSR process. The
// `'server-only'` import guarantees it can never be pulled into a client bundle
// — the read token stays on the box.
//
// Canonical cross-framework env contract (mirrors `templates/astro-starter/
// .env.example`, `templates/DEPLOYING.md` and `web/lib/bp-env.ts`) — the NAMES
// are identical across every adapter:
//
//   BARKPARK_API_URL    the API base — a bare origin (e.g.
//                       https://guerrilla.barkpark.cloud) or an already-SCOPED
//                       `<origin>/w/:ws/p/:proj`
//   BARKPARK_TOKEN      server-only read token (NEVER a NEXT_PUBLIC_-prefixed
//                       var — Next would inline that into the client bundle)
//   BARKPARK_DATASET    dataset name (e.g. "production")
//   BARKPARK_WORKSPACE  workspace slug — only consulted when BARKPARK_API_URL is
//   BARKPARK_PROJECT    project slug     NOT already scoped (belt-and-suspenders)
//   BARKPARK_DOC_TYPE   document type to feature (default "paper")
//   BARKPARK_DOC_ID     specific document id to feature (optional; when unset,
//                       the newest published document of BARKPARK_DOC_TYPE)
//   BARKPARK_SITE_BASE  the `/sites/<slug>/` path Caddy serves this site under
//
// Deploy markers — read at REQUEST time (the page is `force-dynamic`) so they
// reflect the NODE-SLOT BOOT env the deploy engine injects at launch, not the
// build-time values:
//   BUILD_ID       immutable id of the build this slot is serving
//   CONTENT_REV    the content revision the build was cut against
// (The astro-parity BARKPARK_BUILD_ID / BARKPARK_CONTENT_REV names are honored
//  as a fallback so the same values work under either runtime target.)

import 'server-only'

import { createClient, BarkparkNotFoundError, type BarkparkClient } from '@barkpark/core'

/** Barkpark API version this template pins its reads to. */
const API_VERSION = '2026-04-01'

export interface BpEnv {
  /** API base — bare origin or already-scoped `<origin>/w/:ws/p/:proj`. */
  apiUrl: string
  /** Server-only read token, or undefined for anonymous public reads. */
  token: string | undefined
  dataset: string
  /** Only used when `apiUrl` is not already scoped. */
  workspace: string | undefined
  project: string | undefined
  docType: string
  docId: string | undefined
  buildId: string
  contentRev: string
  /** The `/sites/<slug>/` path this site is served under (baked as a marker). */
  siteBase: string
}

class BpConfigError extends Error {}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const v = env[name]
  if (typeof v !== 'string' || v.trim().length === 0) {
    throw new BpConfigError(
      `Missing required env var ${name}. See .env.example for the full contract.`,
    )
  }
  return v.trim()
}

/**
 * Resolve the request-time env contract. Throws a clear error when a required
 * var is absent so a misconfigured slot fails LOUD (→ 500 → the deploy engine's
 * HTTP HEALTH probe fails → the slot never takes the Caddy upstream, last-good
 * keeps serving). This is the container analog of astro-starter failing the
 * build — the fail-closed guarantee, just at boot instead of build.
 */
export function resolveEnv(env: NodeJS.ProcessEnv = process.env): BpEnv {
  return {
    apiUrl: required(env, 'BARKPARK_API_URL'),
    dataset: required(env, 'BARKPARK_DATASET'),
    // Token is optional: a fully public dataset reads anonymously. When set it
    // must NOT be a NEXT_PUBLIC_-prefixed var — see the .env.example gotcha.
    token: env.BARKPARK_TOKEN?.trim() || undefined,
    workspace: env.BARKPARK_WORKSPACE?.trim() || undefined,
    project: env.BARKPARK_PROJECT?.trim() || undefined,
    // Default "paper": guerrilla's `production` dataset has 100 published
    // papers and NO `post` schema (a `post` read 404s). "post" is the canonical
    // cross-adapter default, but "paper" is the safe populated default here.
    docType: env.BARKPARK_DOC_TYPE?.trim() || 'paper',
    docId: env.BARKPARK_DOC_ID?.trim() || undefined,
    // Markers read the node-slot BOOT env first (BUILD_ID / CONTENT_REV), then
    // the astro-parity names, then dev sentinels so a local `next dev` renders.
    buildId: env.BUILD_ID?.trim() || env.BARKPARK_BUILD_ID?.trim() || 'dev',
    contentRev: env.CONTENT_REV?.trim() || env.BARKPARK_CONTENT_REV?.trim() || 'unknown',
    siteBase: env.BARKPARK_SITE_BASE?.trim() || '/sites/next-starter/',
  }
}

/**
 * True when `url`'s path already carries a `/w/:ws/p/:proj` scope. When it does,
 * we pass it straight through and do NOT set workspace/project on the client
 * (which would double-prefix the scope).
 */
function isScopedUrl(url: string): boolean {
  try {
    return /\/w\/[^/]+\/p\/[^/]+\/?$/.test(new URL(url).pathname)
  } catch {
    return false
  }
}

/**
 * Build a FRESH `@barkpark/core` client bound to this request's scoped URL +
 * token. Deliberately NOT `createPreloader` (that helper bleeds request state
 * across module scope — a Next.js footgun the astro-starter README calls out).
 */
function createBpClient(env: BpEnv): BarkparkClient {
  const scoped = isScopedUrl(env.apiUrl)
  return createClient({
    projectUrl: env.apiUrl,
    dataset: env.dataset,
    apiVersion: API_VERSION,
    perspective: 'published',
    ...(env.token ? { token: env.token } : {}),
    // Only when the URL is NOT already scoped do we let core compute the
    // `/w/:ws/p/:proj` prefix from these — otherwise the scope is doubled.
    ...(!scoped && env.workspace ? { workspace: env.workspace } : {}),
    ...(!scoped && env.project ? { project: env.project } : {}),
  })
}

export interface FlagshipDoc {
  _id: string
  title: string
}

export interface FlagshipResult {
  /** The featured document, or null when the dataset has none of `docType`. */
  doc: FlagshipDoc | null
}

function toFlagship(doc: Record<string, unknown> | null | undefined): FlagshipDoc | null {
  if (!doc || typeof doc._id !== 'string') return null
  const rawTitle = doc.title
  const title = typeof rawTitle === 'string' && rawTitle.length > 0 ? rawTitle : doc._id
  return { _id: doc._id, title }
}

/**
 * Fetch the one document this site features, at REQUEST time, via the
 * token-authed `@barkpark/core` client's fluent reads — the SAME path the
 * astro-starter uses. (An earlier version routed this through
 * `@barkpark/nextjs`'s `createBarkparkServer`/`barkparkFetch`, which put the
 * read token in `serverToken` — the draft-preview slot — so the published
 * content query went out ANONYMOUS and a token-required dataset answered 403,
 * 500ing every SSR request. `createBpClient` already carries the token in the
 * Authorization header, so read straight from it.)
 *
 * Fail-closed semantics, mirroring the astro-starter:
 *   - a network / auth error THROWS → the page 500s → HEALTH fails → the slot
 *     never takes traffic (last-good keeps serving);
 *   - a Branch-2 404 (the schema/type is missing or private on this dataset) is
 *     CAUGHT here — `@barkpark/core` raises `BarkparkNotFoundError`, which we
 *     swallow and return null rather than 500 — so the site renders an
 *     honest-empty 200 instead of crashing;
 *   - a reachable-but-empty type (zero documents) returns `{ doc: null }` too.
 */
export async function fetchFlagshipDoc(env: BpEnv): Promise<FlagshipResult> {
  const bp = createBpClient(env)

  try {
    if (env.docId) {
      const doc = await bp.doc(env.docType, env.docId)
      return { doc: toFlagship(doc as Record<string, unknown> | null) }
    }
    const doc = await bp
      .docs(env.docType)
      .order('_updatedAt:desc')
      .limit(1)
      .findOne()
    return { doc: toFlagship(doc as Record<string, unknown> | null) }
  } catch (err) {
    // Branch-2 404 → honest-empty. Every other error re-throws so the
    // fail-closed HEALTH gate can catch a genuinely broken content link.
    if (err instanceof BarkparkNotFoundError) return { doc: null }
    throw err
  }
}
