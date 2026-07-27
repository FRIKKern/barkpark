// Papers cache v1 store laws (mob-w3-papers-cache, D42).
//
// The point of this suite is that it runs the REAL cache SQL — schema
// creation, upsert, rev-compare, schema_version wipe, LRU eviction — through
// node:sqlite's DatabaseSync (available unflagged on node 22, CI's major),
// injected through the same 3-method SqlDriver seam expo-sqlite satisfies on
// device. A memory-Map assertion here would be a tautology; sqlite_master and
// raw SELECTs below are the non-tautological witnesses.
//
// NAMED MUTANTS each block kills (the wave's law — a law that survives its
// own deletion is not pinned):
//   • drop-the-WITHOUT-ROWID / widen-the-PK  → schema pin reds
//   • delete-the-init-wipe                   → schema_version wipe test reds
//   • delete-the-rev-compare guard in put()  → out-of-order rollback test reds
//   • delete-the-evict statement             → LRU cap test reds
//   • fork-the-hydrate-fold                  → pager parity pins red
/* eslint-disable @typescript-eslint/no-require-imports */
import {
  CACHE_SCHEMA_VERSION,
  CacheStore,
  PAPER_CACHE_CAP,
  createMemoryDriver,
  instanceCacheKey,
  readCachedPaper,
  readCachedPaperList,
  setCacheForTesting,
  writeCachedPaper,
  writeCachedPaperList,
  type SqlDriver,
} from '../src/state/cache'
import { PaperRequestError, classifyPaperFailure, type PaperDoc, type PaperPage } from '../src/api/papers'
import { EMPTY_PAGER, appendPage, hydrate } from '../src/papers/paperPager'

/* ── the node:sqlite driver (the REAL-SQL leg of the seam) ─────────────────── */

interface NodeStatement {
  run(...params: unknown[]): unknown
  get(...params: unknown[]): unknown
}
interface NodeDatabase {
  exec(sql: string): void
  prepare(sql: string): NodeStatement
}
// No @types/node in this app (charter D31) — a typed require is the sanctioned
// form; jest's node environment provides the module at runtime.
const { DatabaseSync } = require('node:sqlite') as {
  DatabaseSync: new (path: string) => NodeDatabase
}

function nodeDriver(): { driver: SqlDriver; db: NodeDatabase } {
  const db = new DatabaseSync(':memory:')
  const driver: SqlDriver = {
    exec: (sql) => {
      db.exec(sql)
    },
    run: (sql, ...params) => {
      db.prepare(sql).run(...params)
    },
    first: (sql, ...params) =>
      (db.prepare(sql).get(...params) as Record<string, unknown> | undefined) ?? undefined,
  }
  return { driver, db }
}

/** Monotonic injected clock — updated_at must be assertable, not wall time. */
function makeClock(start = 1_000_000): () => number {
  let t = start
  return () => ++t
}

const IID = 'https://bp.example'

function paperDoc(id: string, rev?: string, body = `body of ${id}`): PaperDoc {
  const doc: PaperDoc = { _id: id, title: id, blocks: [{ type: 'paragraph', text: body }] }
  if (rev !== undefined) doc._updatedAt = rev
  return doc
}

function listPage(n: number, opts: { hasMore?: boolean; total?: number; pageLen?: number } = {}): PaperPage {
  const items = Array.from({ length: n }, (_, i) => ({ _id: `paper-${i}`, title: `Paper ${i}` }))
  const page: PaperPage = {
    items,
    pageLen: opts.pageLen ?? n,
    hasMore: opts.hasMore ?? false,
  }
  if (opts.total !== undefined) page.total = opts.total
  return page
}

afterEach(() => setCacheForTesting(undefined))

describe('client_cache schema (real SQL)', () => {
  it('is the 3-col-PK WITHOUT ROWID table D42 rules', () => {
    const { driver, db } = nodeDriver()
    void new CacheStore(driver, makeClock())
    const row = db.prepare(`SELECT sql FROM sqlite_master WHERE name = 'client_cache'`).get() as {
      sql: string
    }
    expect(row.sql).toContain('WITHOUT ROWID')
    expect(row.sql).toContain('PRIMARY KEY (instance_id, kind, cache_key)')
    // and the store survives re-open against the existing table
    expect(() => new CacheStore(driver, makeClock())).not.toThrow()
  })

  it('schema_version bump = blanket wipe at open; current rows survive', () => {
    const { driver, db } = nodeDriver()
    const first = new CacheStore(driver, makeClock())
    first.put(IID, 'paper', 'production/keeper', { keep: true }, '2026-07-01T00:00:00Z')
    // a row from a PREVIOUS schema generation, planted behind the store's back
    db.prepare(`INSERT INTO client_cache VALUES (?, ?, ?, ?, ?, ?)`).run(
      IID,
      'paper',
      'production/ancient',
      CACHE_SCHEMA_VERSION - 1,
      JSON.stringify({ data: { stale: true } }),
      99,
    )
    const reopened = new CacheStore(driver, makeClock())
    expect(reopened.get(IID, 'paper', 'production/ancient')).toBeUndefined()
    const gone = db
      .prepare(`SELECT COUNT(*) AS n FROM client_cache WHERE schema_version <> ?`)
      .get(CACHE_SCHEMA_VERSION) as { n: number }
    expect(gone.n).toBe(0)
    expect(reopened.get(IID, 'paper', 'production/keeper')).toMatchObject({ data: { keep: true } })
  })
})

describe('CacheStore over real SQL', () => {
  it('read-through: a miss is undefined, a put round-trips with the write clock', () => {
    const { driver } = nodeDriver()
    const store = new CacheStore(driver, makeClock(500))
    expect(store.get(IID, 'paper-list', 'production')).toBeUndefined()
    store.put(IID, 'paper-list', 'production', { hello: 'cache' })
    const entry = store.get<{ hello: string }>(IID, 'paper-list', 'production')
    expect(entry?.data).toEqual({ hello: 'cache' })
    expect(entry?.cachedAtMs).toBe(501)
    expect(entry?.rev).toBeUndefined()
  })

  it('rev-compare: an OLDER rev never rolls the cache backwards; a newer one replaces', () => {
    const { driver, db } = nodeDriver()
    const store = new CacheStore(driver, makeClock())
    store.put(IID, 'paper', 'production/p', { body: 'NEWER' }, '2026-07-20T10:00:00Z')
    // out-of-order response with an older _updatedAt: dropped
    store.put(IID, 'paper', 'production/p', { body: 'STALE' }, '2026-07-10T10:00:00Z')
    expect(store.get(IID, 'paper', 'production/p')?.data).toEqual({ body: 'NEWER' })
    const raw = db
      .prepare(`SELECT payload FROM client_cache WHERE cache_key = 'production/p'`)
      .get() as { payload: string }
    expect(raw.payload).toContain('NEWER')
    expect(raw.payload).not.toContain('STALE')
    // genuinely newer rev replaces (the next-open rev-compare landing)
    store.put(IID, 'paper', 'production/p', { body: 'NEWEST' }, '2026-07-25T10:00:00Z')
    const after = store.get<{ body: string }>(IID, 'paper', 'production/p')
    expect(after?.data.body).toBe('NEWEST')
    expect(after?.rev).toBe('2026-07-25T10:00:00Z')
  })

  it(`LRU count-cap: papers cap at ${PAPER_CACHE_CAP} per instance, oldest-written first out; the list kind is untouched`, () => {
    const { driver, db } = nodeDriver()
    const store = new CacheStore(driver, makeClock())
    store.put(IID, 'paper-list', 'production', { list: true })
    const extra = 5
    for (let i = 0; i < PAPER_CACHE_CAP + extra; i++) {
      store.put(IID, 'paper', `production/p${i}`, { i }, `2026-07-01T00:00:${String(i % 60).padStart(2, '0')}Z`)
    }
    const count = db
      .prepare(`SELECT COUNT(*) AS n FROM client_cache WHERE kind = 'paper'`)
      .get() as { n: number }
    expect(count.n).toBe(PAPER_CACHE_CAP)
    for (let i = 0; i < extra; i++) expect(store.get(IID, 'paper', `production/p${i}`)).toBeUndefined()
    expect(store.get(IID, 'paper', `production/p${PAPER_CACHE_CAP + extra - 1}`)).toBeDefined()
    expect(store.get(IID, 'paper-list', 'production')).toBeDefined()
  })

  it('clearInstance drops one instance and leaves the other (the logout hook)', () => {
    const { driver } = nodeDriver()
    const store = new CacheStore(driver, makeClock())
    store.put('https://a.example', 'paper', 'production/x', { a: 1 })
    store.put('https://b.example', 'paper', 'production/x', { b: 2 })
    store.clearInstance('https://a.example')
    expect(store.get('https://a.example', 'paper', 'production/x')).toBeUndefined()
    expect(store.get('https://b.example', 'paper', 'production/x')).toMatchObject({ data: { b: 2 } })
  })

  it('a corrupt payload row is a miss AND is deleted, not left to rot', () => {
    const { driver, db } = nodeDriver()
    const store = new CacheStore(driver, makeClock())
    db.prepare(`INSERT INTO client_cache VALUES (?, ?, ?, ?, ?, ?)`).run(
      IID,
      'paper',
      'production/bad',
      CACHE_SCHEMA_VERSION,
      '{not json',
      7,
    )
    expect(store.get(IID, 'paper', 'production/bad')).toBeUndefined()
    const left = db
      .prepare(`SELECT COUNT(*) AS n FROM client_cache WHERE cache_key = 'production/bad'`)
      .get() as { n: number }
    expect(left.n).toBe(0)
  })
})

describe('papers domain helpers ride the injected store', () => {
  it('writeCachedPaper/readCachedPaper round-trip keyed by dataset/_id with _updatedAt as rev', () => {
    const { driver } = nodeDriver()
    setCacheForTesting(new CacheStore(driver, makeClock()))
    const scope = { projectUrl: 'https://BP.example/', dataset: 'production' }
    writeCachedPaper(scope, paperDoc('p1', '2026-07-20T10:00:00Z'))
    const entry = readCachedPaper(scope, 'p1')
    expect(entry?.data._id).toBe('p1')
    expect(entry?.rev).toBe('2026-07-20T10:00:00Z')
    // instance identity is the NORMALIZED url — casing/trailing-slash drift
    // must not fork the cache
    expect(instanceCacheKey('https://BP.example/')).toBe(instanceCacheKey('https://bp.example'))
    expect(readCachedPaper({ projectUrl: 'https://bp.example', dataset: 'production' }, 'p1')).toBeDefined()
    // …but a DIFFERENT dataset is a different key
    expect(readCachedPaper({ projectUrl: 'https://bp.example', dataset: 'staging' }, 'p1')).toBeUndefined()
  })

  it('writeCachedPaperList/readCachedPaperList carry the raw PaperPage, dataset-keyed', () => {
    const { driver } = nodeDriver()
    setCacheForTesting(new CacheStore(driver, makeClock()))
    const scope = { projectUrl: 'https://bp.example', dataset: 'production' }
    const page = listPage(3, { hasMore: true, total: 537, pageLen: 3 })
    writeCachedPaperList(scope, page)
    expect(readCachedPaperList(scope)?.data).toEqual(page)
    expect(readCachedPaperList({ ...scope, dataset: 'staging' })).toBeUndefined()
  })
})

describe('paperPager.hydrate — the cache fold IS the network fold', () => {
  it('yields byte-identical PagerState to the network path for the same page 0', () => {
    const pages = [
      listPage(3, { hasMore: false, pageLen: 3 }),
      listPage(100, { hasMore: true, total: 537, pageLen: 100 }),
      listPage(0, { hasMore: false, pageLen: 0 }),
    ]
    for (const page of pages) {
      expect(hydrate(page)).toEqual(appendPage(EMPTY_PAGER, page))
    }
  })

  it('preserves the offset/hasMore invariants: offset advances by RAW pageLen, hasMore is the page truth', () => {
    // pageLen deliberately ≠ items.length (docs without _id are dropped
    // upstream) — the offset law must follow pageLen, never items.
    const page = listPage(98, { hasMore: true, total: 537, pageLen: 100 })
    const state = hydrate(page)
    expect(state.offset).toBe(100)
    expect(state.hasMore).toBe(true)
    expect(state.total).toBe(537)
    expect(state.papers).toHaveLength(98)
  })
})

describe('memory fallback driver (last resort) matches the SQL behavior', () => {
  it('round-trips, evicts at the cap, wipes on schema bump, clears per instance', () => {
    const driver = createMemoryDriver()
    const store = new CacheStore(driver, makeClock())
    store.put(IID, 'paper-list', 'production', { list: true })
    for (let i = 0; i < PAPER_CACHE_CAP + 3; i++) store.put(IID, 'paper', `production/p${i}`, { i })
    expect(store.get(IID, 'paper', 'production/p0')).toBeUndefined() // evicted
    expect(store.get(IID, 'paper', `production/p${PAPER_CACHE_CAP + 2}`)).toMatchObject({
      data: { i: PAPER_CACHE_CAP + 2 },
    })
    expect(store.get(IID, 'paper-list', 'production')).toBeDefined()
    store.clearInstance(IID)
    expect(store.get(IID, 'paper-list', 'production')).toBeUndefined()
  })
})

describe('failure classification (the offline-vs-failed copy split rides on this)', () => {
  it('classifies PaperRequestError by its failure class and everything else as server', () => {
    expect(classifyPaperFailure(new PaperRequestError('net down', 'offline'))).toBe('offline')
    expect(classifyPaperFailure(new PaperRequestError('HTTP 500', 'server', 500))).toBe('server')
    expect(classifyPaperFailure(new Error('surprise'))).toBe('server')
    expect(classifyPaperFailure('string throw')).toBe('server')
  })
})
