// Papers reads — GET /v1/data/query/:dataset/paper (list, projected light via
// fields=) and GET /v1/data/doc/:dataset/paper/:id (full doc for the reader).
// Same client seam as tasks/chat (instance.ts makeInstanceClient + fetchRaw).
// READ-ONLY by construction: the Papers tab issues GETs only.
import type { BarkparkClient } from '@barkpark/core'

export interface PaperListItem {
  _id: string
  title: string
  description?: string
  main_tag?: string
  _updatedAt?: string
  _createdAt?: string
}

export interface PaperDoc extends PaperListItem {
  /** The type-keyed PortableDocument block array the native renderer walks. */
  blocks: unknown[]
}

interface QueryEnvelope {
  result?: {
    /** returned-page row count — NOT a corpus total */
    count?: number
    /** corpus total, present only with `count=true` */
    total?: number
    documents?: Record<string, unknown>[]
  }
}

interface DocEnvelope {
  result?: Record<string, unknown>
}

function asStr(v: unknown): string | undefined {
  return typeof v === 'string' && v !== '' ? v : undefined
}

export const PAPER_PAGE_SIZE = 100

export interface PaperPage {
  items: PaperListItem[]
  /** RAW server page length — the next-offset advance. Kept separate from
   * items.length (docs without an _id are dropped) and from any post-dedupe
   * length, so paging never stalls or skips. */
  pageLen: number
  /** The reliable stop condition (review F3 verify-round): a short page means
   * end-of-corpus. The envelope's `count` is the RETURNED-PAGE row count —
   * NOT a corpus total (probed live: limit=5 → count:5 against 537 papers). */
  hasMore: boolean
  /** Corpus total from `count=true` (docs/api-v1.md §4: "adds result.total";
   * probed live: total:537). Display-only — hasMore never depends on it. */
  total?: number
}

/** One page of the papers list, newest-updated first. `fields=` projects the
 * list light — body_html/blocks payloads stay on the server until a paper is
 * actually opened. System fields (_id, _updatedAt, …) are always kept. */
export async function fetchPaperPage(
  client: BarkparkClient,
  dataset: string,
  offset: number,
): Promise<PaperPage> {
  const path =
    `/v1/data/query/${encodeURIComponent(dataset)}/paper` +
    `?fields=title,description,main_tag&order=_updatedAt:desc` +
    `&limit=${PAPER_PAGE_SIZE}&offset=${Math.max(0, Math.floor(offset))}&count=true`
  const response = await client.fetchRaw<Response>(path)
  if (!response.ok) throw new Error(`paper list failed: HTTP ${response.status}`)
  const body = (await response.json()) as QueryEnvelope
  const docs = body.result?.documents ?? []
  const items: PaperListItem[] = []
  for (const doc of docs) {
    const id = asStr(doc._id)
    if (id === undefined) continue
    items.push({
      _id: id,
      title: asStr(doc.title) ?? id,
      description: asStr(doc.description),
      main_tag: asStr(doc.main_tag),
      _updatedAt: asStr(doc._updatedAt),
      _createdAt: asStr(doc._createdAt),
    })
  }
  const totalRaw = body.result?.total
  const page: PaperPage = {
    items,
    pageLen: docs.length,
    hasMore: docs.length === PAPER_PAGE_SIZE,
  }
  if (typeof totalRaw === 'number' && totalRaw >= 0) page.total = totalRaw
  return page
}

/** Fetch one paper's full document (blocks included) for the reader. */
export async function fetchPaper(client: BarkparkClient, dataset: string, id: string): Promise<PaperDoc> {
  const path = `/v1/data/doc/${encodeURIComponent(dataset)}/paper/${encodeURIComponent(id)}`
  const response = await client.fetchRaw<Response>(path)
  if (!response.ok) throw new Error(`paper fetch failed: HTTP ${response.status}`)
  const body = (await response.json()) as DocEnvelope
  // Envelope-tolerant like core's getDoc: {result: doc} or the flat doc.
  const doc = body.result ?? (body as unknown as Record<string, unknown>)
  const blocks = Array.isArray(doc.blocks) ? doc.blocks : []
  return {
    _id: asStr(doc._id) ?? id,
    title: asStr(doc.title) ?? id,
    description: asStr(doc.description),
    main_tag: asStr(doc.main_tag),
    _updatedAt: asStr(doc._updatedAt),
    _createdAt: asStr(doc._createdAt),
    blocks,
  }
}
