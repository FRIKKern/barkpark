// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Weighted-tag browse reads (authoring-excellence ae-w10):
//   * listTags   — the per-tag registry with per-type published counts
//                  (`GET /v1/data/tags/:dataset`).
//   * getTagDocs — the documents carrying one tag, RANKED BY that tag's
//                  strength (`GET /v1/data/tags/:dataset/:tag`).
// Both are dataset-scoped token reads in the house transport idiom
// (backlinks.ts), fail-closed server-side and published-only by design.
//
// A document's `tags` field is DUAL-SHAPE: each entry is either a weighted
// object `{ tag, strength, rationale }` (wave-2) OR a legacy flat string
// `"name"`. `normalizeTags()` collapses either shape into `{ names, entries }`
// so a consumer never has to branch on the wire form.

import { scopePrefix } from './scope'
import { assertSegment } from './util/guards'
import { request } from './transport'
import { assertNoCommaEntries } from './filter-builder'
import type {
  BarkparkClientConfig,
  ListTagsResult,
  ListTagsOptions,
  TagDocsResult,
  TagDocsOptions,
  WeightedTag,
} from './types'

// The tag reads' `?type=` grammar: a comma list joined for the server (which
// splits on ','), so a comma inside an entry would silently split into extra
// values — fail closed like the graph.ts kinds/sources guards.
function typeQuery(types: string[] | undefined): string {
  if (types === undefined || types.length === 0) return ''
  assertNoCommaEntries(types, 'types')
  return `?type=${encodeURIComponent(types.join(','))}`
}

/**
 * Browse the tag registry — every tag with its per-type published-document
 * counts and a total, biggest first (`GET /v1/data/tags/:dataset`). `types`
 * scopes the corpus (server default `paper,task`). Requires a token (the server
 * 404s an anonymous caller). Prefer `client.listTags()`.
 */
export async function listTags(
  config: BarkparkClientConfig,
  opts?: ListTagsOptions,
): Promise<ListTagsResult> {
  const path = `${scopePrefix(config)}/v1/data/tags/${encodeURIComponent(config.dataset)}${typeQuery(opts?.types)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<ListTagsResult & { result?: ListTagsResult }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as ListTagsResult
}

/**
 * Fetch the documents carrying `tag`, ranked by that tag's strength
 * (`GET /v1/data/tags/:dataset/:tag`). Legacy unweighted carriers rank last.
 * `types` scopes the corpus (server default `paper,task`). Requires a token.
 * Prefer `client.getTagDocs()`.
 */
export async function getTagDocs(
  config: BarkparkClientConfig,
  tag: string,
  opts?: TagDocsOptions,
): Promise<TagDocsResult> {
  // Separators are allowed here and only here: a hierarchical tag `a/b` is a
  // supported tag NAME, and encodeURIComponent collapses it to one `a%2Fb`
  // segment. `.`/`..` are not — they survive the encode and retarget the request.
  assertSegment(tag, 'tag', "tag must be non-empty and not '.' or '..'", true)
  const path =
    `${scopePrefix(config)}/v1/data/tags/${encodeURIComponent(config.dataset)}/${encodeURIComponent(tag)}${typeQuery(opts?.types)}`
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<TagDocsResult & { result?: TagDocsResult }>(
    config,
    path,
    reqOpts,
  )
  return (data.result ?? data) as TagDocsResult
}

/**
 * Collapse a document's dual-shape `tags` field into a uniform view.
 *
 * Each raw entry is either a weighted object `{ tag, strength, rationale }` or a
 * legacy flat string `"name"`. Returns `names` (every tag name, either shape)
 * and `entries` (each as a `WeightedTag`; a flat string becomes
 * `{ tag: name }` with no strength/rationale). Non-string / malformed entries
 * and objects without a string `tag` are skipped. A nullish/non-array input
 * yields empty arrays — never throws.
 */
export function normalizeTags(tags: unknown): { names: string[]; entries: WeightedTag[] } {
  if (!Array.isArray(tags)) return { names: [], entries: [] }
  const names: string[] = []
  const entries: WeightedTag[] = []
  for (const raw of tags) {
    if (typeof raw === 'string') {
      if (raw.length === 0) continue
      names.push(raw)
      entries.push({ tag: raw })
    } else if (raw !== null && typeof raw === 'object') {
      const obj = raw as Record<string, unknown>
      if (typeof obj.tag !== 'string' || obj.tag.length === 0) continue
      const entry: WeightedTag = { tag: obj.tag }
      if (typeof obj.strength === 'number') entry.strength = obj.strength
      if (typeof obj.rationale === 'string') entry.rationale = obj.rationale
      names.push(obj.tag)
      entries.push(entry)
    }
  }
  return { names, entries }
}
