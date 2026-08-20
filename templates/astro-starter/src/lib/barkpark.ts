// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Build-time Barkpark content link for the Astro starter. This module runs
// ONLY at build time (Astro static output) inside Node — never in the browser.
//
// Canonical cross-framework env contract (mirrors `templates/DEPLOYING.md` and
// `web/lib/bp-env.ts`):
//
//   BARKPARK_API_URL    the SCOPED API base — `<origin>/w/:ws/p/:proj`
//                       (e.g. https://guerrilla.barkpark.cloud/w/acme/p/default)
//   BARKPARK_TOKEN      server-only read token (NEVER a PUBLIC_-prefixed var —
//                       Astro would inline a PUBLIC_ var into client JS)
//   BARKPARK_DATASET    dataset name (e.g. "production")
//   BARKPARK_WORKSPACE  workspace slug — only consulted when BARKPARK_API_URL is
//   BARKPARK_PROJECT    project slug     NOT already scoped (belt-and-suspenders)
//
// Deploy markers (baked into output HTML for the deploy engine's HEALTH stage):
//   BARKPARK_BUILD_ID     immutable id of this build
//   BARKPARK_CONTENT_REV  the content revision this build was cut against
//
// Content selection:
//   BARKPARK_DOC_TYPE   document type to feature (default "post")
//   BARKPARK_DOC_ID     specific document id to feature (optional; when unset,
//                       the newest published document of BARKPARK_DOC_TYPE)

import {
  createClient,
  type BarkparkClient,
  type BarkparkDocument,
} from '@barkpark/core'

/** Barkpark API version this template pins its reads to. */
const API_VERSION = '2026-04-01'

export interface BpEnv {
  /** Scoped API base — `<origin>/w/:ws/p/:proj`. */
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
 * Resolve the build-time env contract. Throws a clear error when a required var
 * is absent so a misconfigured deploy fails LOUD at build — never silently
 * shipping an empty or anonymous site by accident.
 */
export function resolveEnv(env: NodeJS.ProcessEnv = process.env): BpEnv {
  return {
    apiUrl: required(env, 'BARKPARK_API_URL'),
    dataset: required(env, 'BARKPARK_DATASET'),
    // Token is optional: a fully public dataset reads anonymously. When set it
    // must NOT be a PUBLIC_-prefixed var — see the .env.example gotcha.
    token: env.BARKPARK_TOKEN?.trim() || undefined,
    workspace: env.BARKPARK_WORKSPACE?.trim() || undefined,
    project: env.BARKPARK_PROJECT?.trim() || undefined,
    docType: env.BARKPARK_DOC_TYPE?.trim() || 'post',
    docId: env.BARKPARK_DOC_ID?.trim() || undefined,
    // Deploy markers default to sentinels so a local `astro dev` still renders;
    // the deploy engine always injects the real values.
    buildId: env.BARKPARK_BUILD_ID?.trim() || 'dev',
    contentRev: env.BARKPARK_CONTENT_REV?.trim() || 'unknown',
  }
}

/**
 * True when `url`'s path already carries a `/w/:ws/p/:proj` scope. When it does,
 * we pass it straight through as `projectUrl` and do NOT set workspace/project
 * on the client (which would double-prefix the scope).
 */
function isScopedUrl(url: string): boolean {
  try {
    return /\/w\/[^/]+\/p\/[^/]+\/?$/.test(new URL(url).pathname)
  } catch {
    return false
  }
}

/**
 * Build a FRESH `@barkpark/core` client for this build. Deliberately NOT
 * memoized and NOT `createPreloader` (that helper is Next.js-specific and leaks
 * request state across module scope). Each build gets its own client bound to
 * this build's scoped URL + token.
 */
export function createBarkparkClient(env: BpEnv): BarkparkClient {
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

export type FlagshipDoc = Pick<BarkparkDocument, '_id'> & {
  title: string
}

export interface FlagshipResult {
  /** The featured document, or null when the dataset has none of `docType`. */
  doc: FlagshipDoc | null
}

function toFlagship(doc: BarkparkDocument | null): FlagshipDoc | null {
  if (!doc || typeof doc._id !== 'string') return null
  const rawTitle = (doc as Record<string, unknown>).title
  const title = typeof rawTitle === 'string' && rawTitle.length > 0 ? rawTitle : doc._id
  return { _id: doc._id, title }
}

/**
 * Fetch the one document this site features, proving the build-time round trip.
 *
 * A network / auth failure THROWS (the build fails — a broken content link must
 * never reach visitors; that is the whole health-gate premise). An empty but
 * reachable dataset returns `{ doc: null }` so the site still builds and renders
 * an honest empty state.
 */
export async function fetchFlagshipDoc(
  bp: BarkparkClient,
  env: BpEnv,
): Promise<FlagshipResult> {
  if (env.docId) {
    const doc = await bp.doc(env.docType, env.docId)
    return { doc: toFlagship(doc) }
  }
  const doc = await bp
    .docs(env.docType)
    .order('_updatedAt:desc')
    .limit(1)
    .findOne()
  return { doc: toFlagship(doc) }
}
