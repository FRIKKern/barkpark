// READ-ENVELOPE `syncTags` ARE METADATA-ONLY **IN THIS REPO**.
// Row het-bl-synctags-read-envelope-pin (charter decision #17 refile of bpb-step7 leg C).
//
// ## The scoped claim, stated exactly
//
// Phoenix puts a `syncTags` array on the READ envelopes
// (`GET /v1/data/doc/...` and `GET /v1/data/query/...` —
// `{ result, syncTags, ms, etag, schemaHash }`). Nothing in THIS repository
// keys a cache off those read-envelope tags: they are carried on the wire,
// discarded by every read path, and never reach `revalidateTag` or Next's
// `next.tags`.
//
// The claim is SCOPED on purpose. A blanket "syncTags are metadata-only" would
// be FALSE:
//
//   * The WEBHOOK path consumes `sync_tags` for real and is separately tested —
//     `js/packages/nextjs/src/revalidate/index.ts` feeds each entry verbatim to
//     `revalidateTag`, and `web/app/api/barkpark/webhook/route.ts` does the same
//     in the demo app.
//   * The SSE path parses `syncTags` onto `ListenEvent` in
//     `js/packages/core/src/listen.ts`.
//   * `@barkpark/nextjs`'s `barkparkFetch` DOES forward an `opts.syncTags` list
//     into `next.tags` — but that list is CALLER-SUPPLIED. No code in this repo
//     reads a response envelope and hands it back through that door.
//   * A DOWNSTREAM user application could read `syncTags` off its own envelope
//     and cache on it. That consumer is invisible to any scan of this repo, so
//     this pin says nothing about it.
//
// ## What reds this file
//
// Wiring read-envelope `syncTags` into anything load-bearing: surfacing them on
// `DocResult`, populating `ResponseContext.syncTags` in `transport.ts`, or
// adding a consumer in a read-path module. That is the point — the ruling is
// recorded here and in `docs/api-v1.md`, and a future change that makes the
// tags load-bearing must come past this file and update both.
//
// ## Non-vacuity
//
// Every absence assertion is paired with a CONTROL that must be PRESENT: the
// same envelope's `etag` reaches `DocResult.etag`, the ETag response header
// reaches `ResponseContext.etag`, and the grep that finds no read-path consumer
// is shown to find the known webhook/SSE consumers with the same reader. An
// empty result from a broken reader cannot pass as an absence.

import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { getDoc } from '../src/doc'
import { createDocsOperation } from '../src/docs'
import type { BarkparkClientConfig, ResponseContext } from '../src/types'

const DOC_REV = 'cafecafecafecafecafecafecafe0001'
const SCHEMA_HASH = 'schema-hash-0001'
// The header is a DIFFERENT token from the body rev (it folds the schema hash).
const CACHE_VALIDATOR = 'beefbeefbeefbeefbeefbeefbeef0002'

// The read-envelope tags under test. Canonical grammar, so a consumer that DID
// wire them up would produce tags that really match the webhook writer's.
const READ_ENVELOPE_SYNC_TAGS = [
  `bp:ds:${TEST_DATASET}:doc:p1`,
  `bp:ds:${TEST_DATASET}:type:post`,
]

const DOC = {
  _id: 'p1',
  _type: 'post',
  _rev: DOC_REV,
  _draft: false,
  _publishedId: 'p1',
  title: 'Hello World',
}

function configWith(hook?: (ctx: ResponseContext) => void): BarkparkClientConfig {
  const cfg: BarkparkClientConfig = {
    projectUrl: TEST_BASE_URL,
    dataset: TEST_DATASET,
    apiVersion: '2026-04-17',
  }
  if (hook !== undefined) cfg.onResponse = hook
  return cfg
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('read-envelope syncTags never reach a cache key (scoped to this repo)', () => {
  it('getDoc discards the doc envelope’s syncTags — and keeps the etag (control)', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/${TEST_DATASET}/post/p1`, () =>
        HttpResponse.json(
          {
            result: DOC,
            syncTags: READ_ENVELOPE_SYNC_TAGS,
            etag: DOC_REV,
            schemaHash: SCHEMA_HASH,
            ms: 3,
          },
          { headers: { ETag: `"${CACHE_VALIDATOR}"` } },
        ),
      ),
    )

    const res = await getDoc<typeof DOC>(configWith(), 'post', 'p1')

    // CONTROL: the envelope really arrived and really was parsed.
    expect(res.etag).toBe(DOC_REV)
    expect(res.data?.title).toBe('Hello World')

    // THE PIN: no syncTags anywhere on what the read hands back.
    expect(Object.keys(res).sort()).toEqual(['data', 'etag'])
    expect(JSON.stringify(res)).not.toContain('syncTags')
    expect(JSON.stringify(res)).not.toContain('bp:ds:')
  })

  it('the query-envelope syncTags are discarded by the list executor too', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/query/${TEST_DATASET}/post`, () =>
        HttpResponse.json({
          result: { perspective: 'published', documents: [DOC], count: 1, limit: 20, offset: 0 },
          syncTags: READ_ENVELOPE_SYNC_TAGS,
          etag: DOC_REV,
          schemaHash: SCHEMA_HASH,
          ms: 4,
        }),
      ),
    )

    const docs = await createDocsOperation<typeof DOC>(configWith(), 'post').find()

    // CONTROL: the envelope arrived and unwrapped.
    expect(docs).toHaveLength(1)
    expect(docs[0]?._id).toBe('p1')

    // THE PIN.
    expect(JSON.stringify(docs)).not.toContain('syncTags')
    expect(JSON.stringify(docs)).not.toContain('bp:ds:')
  })

  it('ResponseContext.syncTags is declared but never populated — the hook fires before the body is read', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/${TEST_DATASET}/post/p1`, () =>
        HttpResponse.json(
          { result: DOC, syncTags: READ_ENVELOPE_SYNC_TAGS, etag: DOC_REV, ms: 1 },
          { headers: { ETag: `"${CACHE_VALIDATOR}"` } },
        ),
      ),
    )

    const seen: ResponseContext[] = []
    await getDoc(
      configWith((ctx) => {
        seen.push(ctx)
      }),
      'post',
      'p1',
    )

    expect(seen).toHaveLength(1)
    const ctx = seen[0]!
    // CONTROL: the hook really ran against a real response.
    expect(ctx.status).toBe(200)
    expect(ctx.etag).toBe(CACHE_VALIDATOR)

    // THE PIN: `ResponseContext.syncTags` (types.ts, "from envelope") is the only
    // typed home read-envelope tags have in core, and transport never fills it.
    expect(ctx.syncTags).toBeUndefined()
    expect('syncTags' in ctx).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// Source-scope arm: WHICH modules consume a syncTags VALUE at all.
// ---------------------------------------------------------------------------

const REPO_ROOT = resolve(__dirname, '..', '..', '..', '..')

/** Strip block and line comments so a comment mentioning syncTags is not a consumer. */
function codeOnly(src: string): string {
  return src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1')
}

function syncTagCodeLines(relPath: string): string[] {
  const src = codeOnly(readFileSync(resolve(REPO_ROOT, relPath), 'utf8'))
  return src
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => /syncTags|sync_tags/i.test(l))
}

describe('source scope — no read-path module consumes envelope syncTags', () => {
  it('transport.ts, the one place a read envelope could be intercepted, never mentions syncTags', () => {
    const lines = syncTagCodeLines('js/packages/core/src/transport.ts')
    expect(lines).toEqual([])

    // CONTROL: the same reader on the same file DOES see the adjacent
    // envelope/header metadata it already handles — so `[]` above is an absence,
    // not a file the reader failed to read.
    const src = codeOnly(readFileSync(resolve(REPO_ROOT, 'js/packages/core/src/transport.ts'), 'utf8'))
    expect(src).toContain('respCtx.etag')
    expect(src).toContain('ResponseContext')
  })

  it('the read executors carry syncTags only in prose, never in code', () => {
    for (const f of ['js/packages/core/src/doc.ts', 'js/packages/core/src/docs.ts']) {
      expect(syncTagCodeLines(f), `${f} gained a syncTags code line`).toEqual([])
      // CONTROL: the prose IS there — the file was read and the stripper ran.
      expect(readFileSync(resolve(REPO_ROOT, f), 'utf8')).toContain('syncTags')
    }
  })

  it('the KNOWN consumers are the webhook and SSE paths — the same reader finds them', () => {
    // If this arm ever goes empty, the reader above is broken and every `[]`
    // verdict in this file is worthless.
    expect(syncTagCodeLines('js/packages/nextjs/src/revalidate/index.ts').length).toBeGreaterThan(0)
    expect(syncTagCodeLines('js/packages/core/src/listen.ts').length).toBeGreaterThan(0)
    expect(syncTagCodeLines('web/app/api/barkpark/webhook/route.ts').length).toBeGreaterThan(0)
  })

  it('barkparkFetch takes syncTags from the CALLER, never from a response body', () => {
    const src = codeOnly(
      readFileSync(resolve(REPO_ROOT, 'js/packages/nextjs/src/server/core.ts'), 'utf8'),
    )
    const lines = src
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => /syncTags/i.test(l))

    // CONTROL: the caller-supplied door is present and is what feeds next.tags.
    expect(lines.some((l) => l.includes('opts.syncTags'))).toBe(true)

    // THE PIN, half one: every syncTags code line names either the caller
    // option or the local it becomes.
    for (const l of lines) {
      expect(
        /opts\.syncTags|knownSyncTags|syncTags\?:/.test(l),
        `unexpected syncTags code line in server/core.ts: ${l}`,
      ).toBe(true)
    }

    // THE PIN, half two — the allowlist above CANNOT stand alone. `syncTags?:`
    // is a TYPE-ANNOTATION token and may sit anywhere on a line, including on an
    // inline cast wrapped around a fetched body. A real leak written as
    //   const leaked = (json as unknown as { syncTags?: string[] }).syncTags
    // satisfies the allowlist and would pass. Measured: that mutation was GREEN
    // against half one alone, while the same leak without the cast reddened it.
    // So deny, independently, any syncTags code line that names a response at
    // all — which is what the prose above this arm always claimed it did.
    for (const l of lines) {
      expect(
        /\b(res|response|json|body|envelope|await)\b/.test(l),
        `syncTags code line reads from a response in server/core.ts: ${l}`,
      ).toBe(false)
    }
  })
})
