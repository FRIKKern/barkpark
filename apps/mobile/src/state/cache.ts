// Papers cache v1 — the sqlite read-through cache behind the Papers tab
// (charter D42; executable design /papers/t3code-upgrade-reconnect-offline SB).
//
// ── STATED POLICY (D42 — this comment is the contract of record) ────────────
//   • KINDS: `paper-list` + `paper` ONLY — the recorded D42 narrowing. Tasks,
//     chat, and media stay uncached this wave; a new kind is a new ruling.
//   • READ-THROUGH ON OPEN: a screen reads its cache row when it mounts and
//     then fetches; the 537-paper corpus is NEVER prefetched.
//   • `paper-list` caches page 0 only, dataset-keyed; the pager folds it via
//     paperPager.hydrate() so the cache path yields the identical PagerState
//     shape as the network path.
//   • `paper` bodies are keyed by dataset/_id, LRU COUNT-CAP 50 on updated_at
//     (PAPER_CACHE_CAP) — eviction runs at write time.
//   • INVALIDATION = next-open _updatedAt rev-compare (no listen() subscriber
//     this wave): put() drops writes whose rev is OLDER than the cached row's
//     (out-of-order responses), and the screens replace cache + UI when the
//     network returns a paper at all — so a newer _updatedAt lands on the
//     next open. schema_version bump = blanket wipe at store init.
//     Per-instance clear (`clearInstance`) covers logout/server switch — its
//     CALL SITE is appConfig.ts's clearDepartingInstanceCache, reached from
//     clearConfig() (sign-out) and rememberAndSave() (connect/switch).
//   • IMAGES ARE HONESTLY EXCLUDED from this policy: no image bytes are
//     cached. Offline behavior is the existing labeled placeholder — an
//     unreachable/unresolvable src renders "Image unavailable", never null
//     (pinned in paperRenderer.test.tsx "unresolvable src renders a labeled
//     placeholder" and re-proven on the offline reader in
//     paperReaderOffline.test.tsx).
//   • DIAGRAMS ARE THE SECOND RECORDED EXCLUSION
//     (mob-zb-bl-island-churn-offline): no mermaid bytes and no rendered SVG
//     are cached — the MermaidIsland fetches mermaid from the CDN per mount,
//     so an offline open of a CACHED paper renders every diagram as the
//     honest "could not render" placeholder carrying the verbatim source
//     (the ~4s watchdog turns a hung captive-portal fetch into that same
//     arm). Pinned on the offline reader in paperReaderOffline.test.tsx with
//     the WebView mocked as an ELEMENT, so the island path actually runs.
//
// ── SEAM LAW (jest-probe-proven this wave) ──────────────────────────────────
// expo-sqlite's IMPORT is clean under jest but openDatabaseSync THROWS at
// construction — so the require + open live inside a try in the getter.
// openDatabaseAsync is FORBIDDEN: it returns a REJECTED promise a sync
// try/catch cannot catch. The storage backends are a 3-method SqlDriver
// (exec/run/first) satisfied by BOTH expo-sqlite (execSync/runSync/
// getFirstSync) and node:sqlite's DatabaseSync (jest injects it through
// setCacheForTesting so the suite runs the REAL SQL below); the in-memory
// driver is the last resort, mirroring storage.ts's MemoryStorage.
import type { PaperDoc, PaperPage } from '../api/papers'

export type SqlParam = string | number | null

/** The 3-method storage seam. Every statement the cache issues is one of the
 * SQL constants below — that closed set is what lets MemoryDriver emulate
 * honestly and what keeps the interface this small. */
export interface SqlDriver {
  exec(sql: string): void
  run(sql: string, ...params: SqlParam[]): void
  first(sql: string, ...params: SqlParam[]): Record<string, unknown> | undefined
}

export const CACHE_SCHEMA_VERSION = 1
export const PAPER_CACHE_CAP = 50

export type CacheKind = 'paper-list' | 'paper'
export const PAPER_LIST_KIND: CacheKind = 'paper-list'
export const PAPER_KIND: CacheKind = 'paper'

// 3-col PK, WITHOUT ROWID (D42): the composite key IS the row identity.
const SQL_CREATE = `CREATE TABLE IF NOT EXISTS client_cache (
  instance_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  cache_key TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  payload TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (instance_id, kind, cache_key)
) WITHOUT ROWID`
const SQL_WIPE_OLD_SCHEMA = `DELETE FROM client_cache WHERE schema_version <> ?`
const SQL_GET = `SELECT schema_version, payload, updated_at FROM client_cache WHERE instance_id = ? AND kind = ? AND cache_key = ?`
const SQL_PUT = `INSERT INTO client_cache (instance_id, kind, cache_key, schema_version, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (instance_id, kind, cache_key) DO UPDATE SET schema_version = excluded.schema_version, payload = excluded.payload, updated_at = excluded.updated_at`
const SQL_EVICT = `DELETE FROM client_cache WHERE instance_id = ? AND kind = ? AND cache_key NOT IN (
  SELECT cache_key FROM client_cache WHERE instance_id = ? AND kind = ? ORDER BY updated_at DESC LIMIT ${PAPER_CACHE_CAP})`
const SQL_CLEAR_INSTANCE = `DELETE FROM client_cache WHERE instance_id = ?`
const SQL_DELETE_ROW = `DELETE FROM client_cache WHERE instance_id = ? AND kind = ? AND cache_key = ?`

/** Payload envelope: the content rev (_updatedAt) rides INSIDE the payload —
 * the row's updated_at is the LRU/staleness clock (write time, ms). */
interface Envelope {
  rev?: string
  data: unknown
}

export interface CachedEntry<T> {
  data: T
  /** content rev (`_updatedAt`) when the domain has one */
  rev?: string
  /** when this row was written (ms) — the stale badge's clock */
  cachedAtMs: number
}

export class CacheStore {
  constructor(
    private readonly driver: SqlDriver,
    private readonly now: () => number = Date.now,
  ) {
    driver.exec(SQL_CREATE)
    // schema_version bump = blanket wipe: rows from any other version die at
    // open, before a single read can hand out a stale-shaped payload.
    driver.run(SQL_WIPE_OLD_SCHEMA, CACHE_SCHEMA_VERSION)
  }

  get<T>(instanceId: string, kind: CacheKind, cacheKey: string): CachedEntry<T> | undefined {
    const row = this.driver.first(SQL_GET, instanceId, kind, cacheKey)
    if (row === undefined) return undefined
    if (row.schema_version !== CACHE_SCHEMA_VERSION) return undefined // belt: init already wiped
    if (typeof row.payload !== 'string' || typeof row.updated_at !== 'number') return undefined
    let envelope: Envelope
    try {
      envelope = JSON.parse(row.payload) as Envelope
    } catch {
      // A corrupt row is a miss, and it must not stay to corrupt the next open.
      this.driver.run(SQL_DELETE_ROW, instanceId, kind, cacheKey)
      return undefined
    }
    const entry: CachedEntry<T> = { data: envelope.data as T, cachedAtMs: row.updated_at }
    if (typeof envelope.rev === 'string') entry.rev = envelope.rev
    return entry
  }

  /** Upsert with rev-compare: a write whose rev is STRICTLY OLDER than the
   * cached row's rev is dropped (out-of-order network responses must never
   * roll the cache backwards). ISO-8601 revs compare lexicographically. */
  put(instanceId: string, kind: CacheKind, cacheKey: string, data: unknown, rev?: string): void {
    if (rev !== undefined) {
      const existing = this.get(instanceId, kind, cacheKey)
      if (existing?.rev !== undefined && rev < existing.rev) return
    }
    const envelope: Envelope = rev !== undefined ? { rev, data } : { data }
    this.driver.run(
      SQL_PUT,
      instanceId,
      kind,
      cacheKey,
      CACHE_SCHEMA_VERSION,
      JSON.stringify(envelope),
      this.now(),
    )
    // LRU count-cap: only `paper` bodies accumulate unboundedly (one list row
    // per dataset caps itself), so only they are evicted.
    if (kind === PAPER_KIND) this.driver.run(SQL_EVICT, instanceId, kind, instanceId, kind)
  }

  /** Per-instance clear — the logout/server-switch hook (policy above). */
  clearInstance(instanceId: string): void {
    this.driver.run(SQL_CLEAR_INSTANCE, instanceId)
  }
}

/* ── drivers ────────────────────────────────────────────────────────────────── */

interface MemoryRow {
  schema_version: number
  payload: string
  updated_at: number
}

/** Last-resort in-memory driver: emulates exactly the closed statement set
 * above (the store's SQL constants are its dispatch keys). Process-lifetime
 * caching only — an app relaunch starts cold, which is honest for a fallback. */
class MemoryDriver implements SqlDriver {
  private rows = new Map<string, MemoryRow>()

  private static key(instanceId: SqlParam, kind: SqlParam, cacheKey: SqlParam): string {
    return `${String(instanceId)} ${String(kind)} ${String(cacheKey)}`
  }

  exec(_sql: string): void {
    // SQL_CREATE — the map is the table.
  }

  run(sql: string, ...params: SqlParam[]): void {
    if (sql === SQL_WIPE_OLD_SCHEMA) {
      for (const [k, row] of this.rows) if (row.schema_version !== params[0]) this.rows.delete(k)
    } else if (sql === SQL_PUT) {
      const [instanceId, kind, cacheKey, schemaVersion, payload, updatedAt] = params
      this.rows.set(MemoryDriver.key(instanceId ?? null, kind ?? null, cacheKey ?? null), {
        schema_version: typeof schemaVersion === 'number' ? schemaVersion : 0,
        payload: typeof payload === 'string' ? payload : '',
        updated_at: typeof updatedAt === 'number' ? updatedAt : 0,
      })
    } else if (sql === SQL_EVICT) {
      const prefix = `${String(params[0])} ${String(params[1])} `
      const group = [...this.rows.entries()].filter(([k]) => k.startsWith(prefix))
      group.sort((a, b) => b[1].updated_at - a[1].updated_at)
      for (const [k] of group.slice(PAPER_CACHE_CAP)) this.rows.delete(k)
    } else if (sql === SQL_CLEAR_INSTANCE) {
      const prefix = `${String(params[0])} `
      for (const k of this.rows.keys()) if (k.startsWith(prefix)) this.rows.delete(k)
    } else if (sql === SQL_DELETE_ROW) {
      this.rows.delete(MemoryDriver.key(params[0] ?? null, params[1] ?? null, params[2] ?? null))
    }
  }

  first(sql: string, ...params: SqlParam[]): Record<string, unknown> | undefined {
    if (sql !== SQL_GET) return undefined
    const row = this.rows.get(MemoryDriver.key(params[0] ?? null, params[1] ?? null, params[2] ?? null))
    if (row === undefined) return undefined
    return { schema_version: row.schema_version, payload: row.payload, updated_at: row.updated_at }
  }
}

/** Exported for the fallback-parity test — production reaches it only through
 * getCacheStore()'s catch arm. */
export function createMemoryDriver(): SqlDriver {
  return new MemoryDriver()
}

function openExpoDriver(): SqlDriver {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const sqlite = require('expo-sqlite') as typeof import('expo-sqlite')
  const db = sqlite.openDatabaseSync('barkpark-client-cache.db')
  return {
    exec: (sql) => {
      db.execSync(sql)
    },
    run: (sql, ...params) => {
      db.runSync(sql, params)
    },
    first: (sql, ...params) =>
      db.getFirstSync<Record<string, unknown>>(sql, params) ?? undefined,
  }
}

let store: CacheStore | undefined

export function getCacheStore(): CacheStore {
  if (store !== undefined) return store
  try {
    // openDatabaseSync THROWS under jest / Expo Go without a dev build — the
    // try is the seam (openDatabaseAsync would reject instead: forbidden).
    store = new CacheStore(openExpoDriver())
  } catch {
    store = new CacheStore(new MemoryDriver())
  }
  return store
}

/** Test seam: replace the cache store (pass undefined to reset). Mirrors
 * storage.ts's setStorageForTesting. */
export function setCacheForTesting(next: CacheStore | undefined): void {
  store = next
}

/* ── papers domain helpers (the two D42 kinds) ──────────────────────────────── */

/** The cache's instance identity: the normalized connected-server URL. The
 * cascade's InstanceID would be stronger but is not plumbed into
 * InstanceConnection; the URL is stable per server and is what a server
 * switch actually changes. */
export function instanceCacheKey(projectUrl: string): string {
  return projectUrl.trim().replace(/\/+$/, '').toLowerCase()
}

interface CacheScope {
  projectUrl: string
  dataset: string
}

export function readCachedPaperList(scope: CacheScope): CachedEntry<PaperPage> | undefined {
  return getCacheStore().get<PaperPage>(instanceCacheKey(scope.projectUrl), PAPER_LIST_KIND, scope.dataset)
}

export function writeCachedPaperList(scope: CacheScope, page: PaperPage): void {
  getCacheStore().put(instanceCacheKey(scope.projectUrl), PAPER_LIST_KIND, scope.dataset, page)
}

export function readCachedPaper(scope: CacheScope, id: string): CachedEntry<PaperDoc> | undefined {
  return getCacheStore().get<PaperDoc>(instanceCacheKey(scope.projectUrl), PAPER_KIND, `${scope.dataset}/${id}`)
}

export function writeCachedPaper(scope: CacheScope, paper: PaperDoc): void {
  getCacheStore().put(
    instanceCacheKey(scope.projectUrl),
    PAPER_KIND,
    `${scope.dataset}/${paper._id}`,
    paper,
    paper._updatedAt,
  )
}
