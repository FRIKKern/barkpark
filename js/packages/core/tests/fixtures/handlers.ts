// Test-only MSW 2.x handlers. Runtime-agnostic (uses HttpResponse + http from 'msw').
// Handlers simulate Phoenix /v1 behavior documented in w6.3-phoenix-contract.md.
// Shapes verified against:
//   - packages/core/src/types.ts (MetaResponse, ReadEnvelope, MutateEnvelope, ListenEvent)
//   - scratchpad/w6.3-phoenix-contract.md (§meta, §query, §mutate, §listen, §error envelope)
import { http, HttpResponse, delay } from 'msw'
import type {
  MetaResponse,
  ReadEnvelope,
  MutateEnvelope,
  MutateResult,
  BarkparkDocument,
} from '../../src/types'

const BASE = 'http://test.barkpark.local'
const DATASET = 'production'
const API_VERSION = '2026-04-17'
const SCHEMA_HASH = 'abc1234567890def'                                  // 16-hex (per contract §meta)
const TX_ID = 'aabbccddeeff00112233445566778899'                        // 32-hex (per contract §mutate)
const LIST_ETAG = 'deadbeefcafebabef00dfaceabcdef01'                    // 32-hex per contract §query headers
const DEFAULT_REV = '0123456789abcdef0123456789abcdef'                  // 32-hex doc rev

/** Build a document envelope matching `api/lib/barkpark/content/envelope.ex`. */
function doc(partial: Partial<BarkparkDocument> & { _id: string; _type: string }): BarkparkDocument {
  const draft = partial._id.startsWith('drafts.')
  const publishedId = draft ? partial._id.replace(/^drafts\./, '') : partial._id
  return {
    _rev: partial._rev ?? DEFAULT_REV,
    _draft: draft,
    _publishedId: publishedId,
    _createdAt: '2026-04-12T09:11:20Z',
    _updatedAt: '2026-04-12T09:11:20Z',
    ...partial,
  } as BarkparkDocument
}

const SEED_DOCS: BarkparkDocument[] = [
  doc({ _id: 'p1', _type: 'post', _rev: '1111111111111111111111111111aaaa', title: 'Hello World' }),
  doc({ _id: 'drafts.p2', _type: 'post', _rev: '2222222222222222222222222222bbbb', title: 'Draft Post' }),
  doc({ _id: 'b1', _type: 'book', _rev: '3333333333333333333333333333cccc', title: 'Example Book' }),
]

/** In-memory fixture store — tests mutate; resetFixtures() restores seed. */
export const fixtures = {
  meta: {
    minApiVersion: '2026-04-01',
    maxApiVersion: API_VERSION,
    serverTime: '2026-04-18T00:00:00.000Z',
    currentDatasetSchemaHash: SCHEMA_HASH,
  } as MetaResponse,
  multiMeta: {
    minApiVersion: '2026-04-01',
    maxApiVersion: API_VERSION,
    serverTime: '2026-04-18T00:00:00.000Z',
    currentDatasetSchemaHash: { [DATASET]: SCHEMA_HASH, staging: 'fedcba9876543210' },
  } as MetaResponse,
  docs: [...SEED_DOCS],
  apiVersion: API_VERSION,
  schemaHash: SCHEMA_HASH,
}

export function resetFixtures() {
  fixtures.docs = [...SEED_DOCS]
}

/** Sync-tag builders matching api/lib/barkpark/content.ex tag scheme. */
const tagType = (type: string) => `bp:ds:${DATASET}:type:${type}`
const tagDoc = (id: string) => `bp:ds:${DATASET}:doc:${id.replace(/^drafts\./, '')}`

/** Default handlers — happy paths. Tests override per-test for error cases. */
export const defaultHandlers = [
  // GET /v1/meta and /v1/meta?dataset=production
  http.get(`${BASE}/v1/meta`, ({ request }) => {
    const url = new URL(request.url)
    const ds = url.searchParams.get('dataset')
    if (ds && ds !== DATASET && ds !== 'staging') {
      return HttpResponse.json(
        { error: { code: 'not_found', message: 'dataset not found', request_id: 'req_meta_404' } },
        { status: 404, headers: { 'x-request-id': 'req_meta_404' } },
      )
    }
    const body = ds ? fixtures.meta : fixtures.multiMeta
    return HttpResponse.json(body, { status: 200, headers: { 'x-request-id': 'req_meta_1' } })
  }),

  // GET /v1/data/query/:dataset/:type
  http.get(`${BASE}/v1/data/query/:dataset/:type`, ({ params, request }) => {
    const { type } = params as { dataset: string; type: string }
    const url = new URL(request.url)
    const perspective = (url.searchParams.get('perspective') ?? 'published') as
      | 'published'
      | 'drafts'
      | 'raw'
    const limit = Number(url.searchParams.get('limit') ?? '100')
    const offset = Number(url.searchParams.get('offset') ?? '0')

    let docs = fixtures.docs.filter((d) => d._type === type)
    if (perspective === 'published') docs = docs.filter((d) => !d._draft)
    if (perspective === 'drafts') docs = docs.filter((d) => d._draft)

    // Phoenix filter syntax: filter[<field>]=v (eq) or filter[<field>][<op>]=v.
    // Simplified: support only eq.
    for (const [key, value] of url.searchParams.entries()) {
      const eq = key.match(/^filter\[([^\]]+)\]$/)
      if (eq) {
        const field = eq[1]!
        docs = docs.filter((d) => String((d as Record<string, unknown>)[field]) === value)
      }
    }

    const windowed = docs.slice(offset, offset + limit)
    const envelope: ReadEnvelope<{
      perspective: 'published' | 'drafts' | 'raw'
      documents: BarkparkDocument[]
      count: number
      limit: number
      offset: number
    }> = {
      result: { perspective, documents: windowed, count: windowed.length, limit, offset },
      syncTags: [tagType(type), ...windowed.map((d) => tagDoc(d._id))],
      ms: 3,
      etag: LIST_ETAG,
      schemaHash: fixtures.schemaHash,
    }

    const ifNoneMatch = request.headers.get('if-none-match')
    if (ifNoneMatch && ifNoneMatch.replace(/^W\//, '').replace(/^"|"$/g, '') === envelope.etag) {
      return new HttpResponse(null, { status: 304, headers: { 'x-request-id': 'req_query_304' } })
    }

    return HttpResponse.json(envelope, {
      status: 200,
      headers: { ETag: `"${envelope.etag}"`, 'x-request-id': 'req_query_1' },
    })
  }),

  // GET /v1/data/doc/:dataset/:type/:doc_id
  http.get(`${BASE}/v1/data/doc/:dataset/:type/:doc_id`, ({ params, request }) => {
    const { type, doc_id: id } = params as { dataset: string; type: string; doc_id: string }
    const found =
      fixtures.docs.find((d) => d._type === type && d._id === id) ??
      fixtures.docs.find(
        (d) => d._type === type && !d._draft && d._publishedId === id,
      )
    if (!found) {
      return HttpResponse.json(
        { error: { code: 'not_found', message: 'document not found', request_id: 'req_doc_404' } },
        { status: 404, headers: { 'x-request-id': 'req_doc_404' } },
      )
    }
    const envelope: ReadEnvelope<BarkparkDocument> = {
      result: found,
      syncTags: [tagType(type), tagDoc(found._id)],
      ms: 2,
      etag: found._rev,
      schemaHash: fixtures.schemaHash,
    }
    const ifNoneMatch = request.headers.get('if-none-match')
    if (ifNoneMatch && ifNoneMatch.replace(/^W\//, '').replace(/^"|"$/g, '') === found._rev) {
      return new HttpResponse(null, { status: 304, headers: { 'x-request-id': 'req_doc_304' } })
    }
    return HttpResponse.json(envelope, {
      status: 200,
      headers: { ETag: `"${found._rev}"`, 'x-request-id': 'req_doc_1' },
    })
  }),

  // POST /v1/data/mutate/:dataset
  http.post(`${BASE}/v1/data/mutate/:dataset`, async ({ request }) => {
    const auth = request.headers.get('authorization')
    if (!auth || !/^Bearer\s+/.test(auth)) {
      return HttpResponse.json(
        { error: { code: 'unauthorized', message: 'missing bearer token', request_id: 'req_mut_401' } },
        { status: 401, headers: { 'x-request-id': 'req_mut_401' } },
      )
    }

    const body = (await request.json().catch(() => null)) as { mutations?: unknown[] } | null
    if (!body || !Array.isArray(body.mutations)) {
      return HttpResponse.json(
        { error: { code: 'malformed', message: 'missing mutations list', request_id: 'req_mut_400' } },
        { status: 400, headers: { 'x-request-id': 'req_mut_400' } },
      )
    }

    const results: MutateResult[] = []
    let revCounter = fixtures.docs.length + 1

    for (const m of body.mutations as Array<Record<string, unknown>>) {
      const nextRev = () => {
        const n = String(revCounter++).padStart(4, '0')
        return `${n}${n}${n}${n}${n}${n}${n}${n}`   // 32 chars, all hex
      }

      if ('create' in m) {
        const input = m['create'] as Partial<BarkparkDocument> & { _type: string }
        const id = input._id ?? `drafts.${input._type}-${results.length + 1}`
        if (fixtures.docs.some((d) => d._id === id)) {
          return HttpResponse.json(
            { error: { code: 'conflict', message: `document ${id} already exists`, request_id: 'req_mut_409' } },
            { status: 409, headers: { 'x-request-id': 'req_mut_409' } },
          )
        }
        const fresh = doc({
          ...input,
          _id: id,
          _type: input._type,
          _rev: nextRev(),
        })
        fresh._updatedAt = new Date().toISOString()
        fresh._createdAt = fresh._updatedAt
        fixtures.docs.push(fresh)
        results.push({ id: fresh._id, operation: 'create', document: fresh })
        continue
      }

      if ('patch' in m) {
        const p = m['patch'] as { id: string; type: string; set?: Record<string, unknown>; ifMatch?: string }
        const target = fixtures.docs.find((d) => d._id === p.id && d._type === p.type)
        if (!target) {
          return HttpResponse.json(
            { error: { code: 'not_found', message: 'patch target missing', request_id: 'req_mut_404' } },
            { status: 404, headers: { 'x-request-id': 'req_mut_404' } },
          )
        }
        if (p.ifMatch && p.ifMatch !== target._rev) {
          return HttpResponse.json(
            {
              error: {
                code: 'precondition_failed',
                message: 'document revision mismatch',
                request_id: 'req_mut_412',
                details: { expected: p.ifMatch, actual: target._rev },
              },
            },
            { status: 412, headers: { 'x-request-id': 'req_mut_412' } },
          )
        }
        Object.assign(target, p.set ?? {})
        target._rev = nextRev()
        target._updatedAt = new Date().toISOString()
        results.push({ id: target._id, operation: 'update', document: target })
        continue
      }

      if ('publish' in m) {
        const { id, type } = m['publish'] as { id: string; type: string }
        const draftId = `drafts.${id}`
        const draft = fixtures.docs.find((d) => d._id === draftId && d._type === type)
        if (!draft) {
          return HttpResponse.json(
            { error: { code: 'not_found', message: 'draft missing', request_id: 'req_mut_404' } },
            { status: 404, headers: { 'x-request-id': 'req_mut_404' } },
          )
        }
        draft._id = id
        draft._draft = false
        draft._rev = nextRev()
        draft._updatedAt = new Date().toISOString()
        results.push({ id: draft._id, operation: 'publish', document: draft })
        continue
      }

      if ('unpublish' in m) {
        const { id, type } = m['unpublish'] as { id: string; type: string }
        const pub = fixtures.docs.find((d) => d._id === id && d._type === type && !d._draft)
        if (!pub) {
          return HttpResponse.json(
            { error: { code: 'not_found', message: 'published doc missing', request_id: 'req_mut_404' } },
            { status: 404, headers: { 'x-request-id': 'req_mut_404' } },
          )
        }
        pub._id = `drafts.${pub._publishedId}`
        pub._draft = true
        pub._rev = nextRev()
        pub._updatedAt = new Date().toISOString()
        results.push({ id: pub._id, operation: 'unpublish', document: pub })
        continue
      }

      if ('delete' in m) {
        const { id, type } = m['delete'] as { id: string; type: string }
        const idx = fixtures.docs.findIndex((d) => d._id === id && d._type === type)
        if (idx < 0) {
          return HttpResponse.json(
            { error: { code: 'not_found', message: 'delete target missing', request_id: 'req_mut_404' } },
            { status: 404, headers: { 'x-request-id': 'req_mut_404' } },
          )
        }
        const [removed] = fixtures.docs.splice(idx, 1)
        results.push({ id: removed!._id, operation: 'delete', document: removed! })
        continue
      }

      return HttpResponse.json(
        { error: { code: 'malformed', message: 'unknown op shape', request_id: 'req_mut_400' } },
        { status: 400, headers: { 'x-request-id': 'req_mut_400' } },
      )
    }

    const envelope: MutateEnvelope = { transactionId: TX_ID, results }
    return HttpResponse.json(envelope, { status: 200, headers: { 'x-request-id': 'req_mut_1' } })
  }),

  // GET /v1/data/listen/:dataset → SSE stream
  http.get(`${BASE}/v1/data/listen/:dataset`, ({ request }) => {
    const auth = request.headers.get('authorization')
    if (!auth || !/^Bearer\s+/.test(auth)) {
      return HttpResponse.json(
        { error: { code: 'unauthorized', message: 'missing bearer token', request_id: 'req_listen_401' } },
        { status: 401, headers: { 'x-request-id': 'req_listen_401' } },
      )
    }
    const stream = new ReadableStream<Uint8Array>({
      async start(controller) {
        const enc = new TextEncoder()
        // welcome frame (per contract §listen: no id, data: {"type":"welcome"})
        controller.enqueue(enc.encode(`event: welcome\ndata: ${JSON.stringify({ type: 'welcome' })}\n\n`))
        await delay(5)
        // mutation frame: eventId 1
        const mut = {
          eventId: 1,
          mutation: 'create',
          type: 'post',
          documentId: 'drafts.live-x1',
          rev: '4444444444444444444444444444dddd',
          previousRev: null,
          result: doc({ _id: 'drafts.live-x1', _type: 'post', _rev: '4444444444444444444444444444dddd', title: 'Live!' }),
          syncTags: [tagType('post'), tagDoc('drafts.live-x1')],
        }
        controller.enqueue(enc.encode(`id: 1\nevent: mutation\ndata: ${JSON.stringify(mut)}\n\n`))
        await delay(5)
        // keepalive comment
        controller.enqueue(enc.encode(`: keepalive\n\n`))
        controller.close()
      },
    })
    return new HttpResponse(stream, {
      status: 200,
      headers: {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        connection: 'keep-alive',
        'x-request-id': 'req_listen_1',
      },
    })
  }),
]

/** Error-envelope response builder — reusable by per-test handler overrides. */
export function errorResponse(opts: {
  status: number
  code: string
  message: string
  details?: Record<string, unknown>
}) {
  const requestId = `req_err_${Math.random().toString(36).slice(2, 8)}`
  return HttpResponse.json(
    {
      error: {
        code: opts.code,
        message: opts.message,
        request_id: requestId,
        ...(opts.details ? { details: opts.details } : {}),
      },
    },
    { status: opts.status, headers: { 'x-request-id': requestId } },
  )
}

export const TEST_BASE_URL = BASE
export const TEST_DATASET = DATASET
export const TEST_API_VERSION = API_VERSION
export const TEST_SCHEMA_HASH = SCHEMA_HASH
export const TEST_TX_ID = TX_ID
