// Cache-first screen wiring probes (mob-w3-papers-cache, D42) — the REAL
// PapersScreen and PaperReaderScreen mounted with react-test-renderer over a
// REAL sqlite cache (node:sqlite through the SqlDriver seam, injected via
// setCacheForTesting). The network layer is the only mock.
//
// NAMED MUTANTS each probe kills (a probe that no mutant reds is decoration):
//   • delete-the-cache-read   → cold-hit-offline probes red into the error
//                               state instead of painting the cached body
//   • collapse-the-messages   → the offline/failed copy-distinction probes red
//   • drop-the-write          → the write-through row probe reds AND the
//                               fetch-then-offline-relaunch probe cold-misses
//   • prefer-cache-always     → the newer-network-replaces probe reds (stale
//                               body kept, badge never cleared)
//
// TEARDOWN IS LOAD-BEARING (chatScreenWiring's law): every mount unmounts in
// a finally; fake timers put FlatList's scheduled work under jest's teardown.
import { act, create, type ReactTestRenderer } from 'react-test-renderer'

import type { InstanceConnection } from '../src/api/instance'
import {
  PaperRequestError,
  fetchPaper,
  fetchPaperPage,
  type PaperDoc,
  type PaperPage,
} from '../src/api/papers'
import {
  CACHE_SCHEMA_VERSION,
  CacheStore,
  setCacheForTesting,
  writeCachedPaper,
  writeCachedPaperList,
  type SqlDriver,
} from '../src/state/cache'
import {
  PaperReaderScreen,
  READER_FAILED_COPY,
  READER_OFFLINE_COPY,
} from '../src/screens/PaperReaderScreen'
import { PAPERS_FAILED_COPY, PAPERS_OFFLINE_COPY, PapersScreen } from '../src/screens/PapersScreen'

// (hoisted) Only the NETWORK functions are mocked — PaperRequestError,
// classifyPaperFailure, and the types stay real via requireActual, so the
// screens' instanceof classification runs the real code path.
jest.mock('../src/api/papers', () => ({
  ...jest.requireActual('../src/api/papers'),
  fetchPaper: jest.fn(),
  fetchPaperPage: jest.fn(),
}))
// The WebView is mocked as an ELEMENT, not null (mob-zb-bl-island-churn-offline
// criterion 3): a null stub silently skipped the MermaidIsland path, so no
// offline test ever exercised how a cached paper's diagrams behave. The mock
// renders nothing visible but lets the island mount, arm its watchdog and
// degrade — which is the recorded D42 exclusion behavior under test below.
jest.mock('react-native-webview', () => {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { View } = require('react-native')
  return { WebView: () => <View testID="mermaid-webview" /> }
})
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

const mockFetchPaper = fetchPaper as jest.Mock
const mockFetchPage = fetchPaperPage as jest.Mock

/* ── real-SQL cache backing (same driver shape as papersCache.test.ts) ─────── */

interface NodeStatement {
  run(...params: unknown[]): unknown
  get(...params: unknown[]): unknown
}
interface NodeDatabase {
  exec(sql: string): void
  prepare(sql: string): NodeStatement
}
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { DatabaseSync } = require('node:sqlite') as {
  DatabaseSync: new (path: string) => NodeDatabase
}

let db: NodeDatabase
let clock: number

function freshCache(): void {
  db = new DatabaseSync(':memory:')
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
  clock = 1_000_000
  setCacheForTesting(new CacheStore(driver, () => ++clock))
}

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

const OFFLINE = (): PaperRequestError => new PaperRequestError('network request failed', 'offline')
const SERVER = (): PaperRequestError => new PaperRequestError('HTTP 500', 'server', 500)

function paper(id: string, body: string, rev?: string, extraBlocks: unknown[] = []): PaperDoc {
  const doc: PaperDoc = {
    _id: id,
    title: `Paper ${id}`,
    blocks: [{ type: 'paragraph', text: body }, ...extraBlocks],
  }
  if (rev !== undefined) doc._updatedAt = rev
  return doc
}

function listPage(titles: string[]): PaperPage {
  return {
    items: titles.map((t, i) => ({ _id: `id-${i}`, title: t, _updatedAt: '2026-07-20T10:00:00Z' })),
    pageLen: titles.length,
    hasMore: false,
  }
}

/** Every string leaf the mounted tree paints, in order. */
function textOf(tree: ReactTestRenderer): string {
  const out: string[] = []
  const walk = (node: unknown): void => {
    if (node === null || node === undefined || typeof node === 'boolean') return
    if (typeof node === 'string' || typeof node === 'number') {
      out.push(String(node))
      return
    }
    if (Array.isArray(node)) {
      for (const child of node) walk(child)
      return
    }
    walk((node as { children?: unknown }).children ?? null)
  }
  walk(tree.toJSON())
  return out.join(' ')
}

async function mountReader(paperId = 'p1'): Promise<ReactTestRenderer> {
  let tree: ReactTestRenderer
  await act(async () => {
    tree = create(
      <PaperReaderScreen connection={conn} paperId={paperId} paperTitle="T" onBack={() => {}} />,
    )
  })
  return tree!
}

async function mountList(): Promise<ReactTestRenderer> {
  let tree: ReactTestRenderer
  await act(async () => {
    tree = create(<PapersScreen connection={conn} />)
  })
  return tree!
}

async function unmount(tree: ReactTestRenderer): Promise<void> {
  await act(async () => {
    tree.unmount()
  })
}

beforeEach(() => {
  jest.useFakeTimers()
  mockFetchPaper.mockReset()
  mockFetchPage.mockReset()
  freshCache()
})

afterEach(() => {
  setCacheForTesting(undefined)
  jest.clearAllTimers()
  jest.useRealTimers()
})

describe('PaperReaderScreen offline truth', () => {
  it('cold-hit offline paints the CACHED body with the stale badge (mutant: delete-the-cache-read)', async () => {
    writeCachedPaper(conn, paper('p1', 'CACHED BODY SURVIVES OFFLINE', '2026-07-20T10:00:00Z'))
    mockFetchPaper.mockRejectedValue(OFFLINE())
    const tree = await mountReader()
    try {
      const text = textOf(tree)
      expect(text).toContain('CACHED BODY SURVIVES OFFLINE')
      expect(text).toContain('Cached copy')
      expect(text).not.toContain(READER_OFFLINE_COPY)
      expect(text).not.toContain(READER_FAILED_COPY)
    } finally {
      await unmount(tree)
    }
  })

  it('a cached paper opened OFFLINE renders its diagram through the ISLAND path and degrades honestly (D42 exclusion, mob-zb-bl-island-churn-offline)', async () => {
    // Diagrams are the second recorded D42 offline exclusion (state/cache.ts
    // policy comment): the body paints from cache, the island MOUNTS (WebView
    // is an element here, not a null stub), and — offline, so its CDN document
    // can never report back — the ~4s watchdog degrades it to the labeled
    // placeholder carrying the verbatim source. Never a blank hole.
    const DIAGRAM_SOURCE = 'graph TD; CACHE-->READER'
    writeCachedPaper(
      conn,
      paper('p1', 'BODY WITH A DIAGRAM', '2026-07-20T10:00:00Z', [
        { type: 'diagram', source: DIAGRAM_SOURCE },
      ]),
    )
    mockFetchPaper.mockRejectedValue(OFFLINE())
    const tree = await mountReader()
    try {
      // The island path ran: the WebView element is in the tree...
      expect(tree.root.findAllByProps({ testID: 'mermaid-webview' }).length).toBeGreaterThan(0)
      const before = textOf(tree)
      expect(before).toContain('BODY WITH A DIAGRAM')
      expect(before).toContain('Loading diagram…') // the island says it is working
      // ...and the watchdog turns the dead CDN fetch into the honest degrade.
      await act(async () => {
        jest.advanceTimersByTime(4001)
      })
      const after = textOf(tree)
      expect(after).toContain('could not render')
      expect(after).toContain(DIAGRAM_SOURCE)
      expect(after).not.toContain('Loading diagram…')
    } finally {
      await unmount(tree)
    }
  })

  it('cold-miss offline copy is DISTINCT from the failure copy (mutant: collapse-the-messages)', async () => {
    mockFetchPaper.mockRejectedValue(OFFLINE())
    const offlineTree = await mountReader()
    let offlineText: string
    try {
      offlineText = textOf(offlineTree)
      expect(offlineText).toContain(READER_OFFLINE_COPY)
      expect(offlineText).not.toContain(READER_FAILED_COPY)
    } finally {
      await unmount(offlineTree)
    }

    mockFetchPaper.mockRejectedValue(SERVER())
    const failedTree = await mountReader()
    try {
      const failedText = textOf(failedTree)
      expect(failedText).toContain(READER_FAILED_COPY)
      expect(failedText).not.toContain(READER_OFFLINE_COPY)
      expect(failedText).not.toBe(offlineText)
    } finally {
      await unmount(failedTree)
    }
  })

  it('write-through leaves a real row: schema_version stamped, updated_at monotonic (mutant: drop-the-write)', async () => {
    mockFetchPaper.mockResolvedValue(paper('p1', 'FRESH FROM NETWORK', '2026-07-21T09:00:00Z'))
    const tree = await mountReader()
    let firstWriteAt: number
    try {
      const row = db
        .prepare(
          `SELECT schema_version, updated_at, payload FROM client_cache WHERE kind = 'paper' AND cache_key = 'production/p1'`,
        )
        .get() as { schema_version: number; updated_at: number; payload: string } | undefined
      expect(row).toBeDefined()
      expect(row!.schema_version).toBe(CACHE_SCHEMA_VERSION)
      expect(row!.updated_at).toBeGreaterThan(1_000_000)
      expect(row!.payload).toContain('FRESH FROM NETWORK')
      firstWriteAt = row!.updated_at
    } finally {
      await unmount(tree)
    }

    // a later open re-writes with a LATER clock — monotonic, never equal/backwards
    mockFetchPaper.mockResolvedValue(paper('p1', 'FRESH AGAIN', '2026-07-22T09:00:00Z'))
    const tree2 = await mountReader()
    try {
      const row2 = db
        .prepare(`SELECT updated_at FROM client_cache WHERE cache_key = 'production/p1'`)
        .get() as { updated_at: number }
      expect(row2.updated_at).toBeGreaterThan(firstWriteAt!)
    } finally {
      await unmount(tree2)
    }

    // and the row is EXACTLY what a cold offline open paints (the charter's
    // cross-proof: drop-the-write also reds this leg)
    mockFetchPaper.mockRejectedValue(OFFLINE())
    const tree3 = await mountReader()
    try {
      expect(textOf(tree3)).toContain('FRESH AGAIN')
    } finally {
      await unmount(tree3)
    }
  })

  it('newer _updatedAt from the network replaces the cached body and clears the badge (mutant: prefer-cache-always)', async () => {
    writeCachedPaper(conn, paper('p1', 'OLD CACHED BODY', '2026-07-10T10:00:00Z'))
    mockFetchPaper.mockResolvedValue(paper('p1', 'NEW NETWORK BODY', '2026-07-22T10:00:00Z'))
    const tree = await mountReader()
    try {
      const text = textOf(tree)
      expect(text).toContain('NEW NETWORK BODY')
      expect(text).not.toContain('OLD CACHED BODY')
      expect(text).not.toContain('Cached copy') // badge cleared — network confirmed
      // …and the write-through replaced the cached rev too (next open is fresh)
      const row = db
        .prepare(`SELECT payload FROM client_cache WHERE cache_key = 'production/p1'`)
        .get() as { payload: string }
      expect(row.payload).toContain('NEW NETWORK BODY')
      expect(row.payload).toContain('2026-07-22T10:00:00Z')
    } finally {
      await unmount(tree)
    }
  })

  it('images stay honestly excluded: an unresolvable src on a CACHED offline paper renders the labeled placeholder, never null', async () => {
    writeCachedPaper(
      conn,
      paper('p1', 'prose around the image', '2026-07-20T10:00:00Z', [
        { type: 'image', src: '//unreachable.example/x.png' },
      ]),
    )
    mockFetchPaper.mockRejectedValue(OFFLINE())
    const tree = await mountReader()
    try {
      const text = textOf(tree)
      expect(text).toContain('Image unavailable')
      expect(text).toContain('//unreachable.example/x.png')
    } finally {
      await unmount(tree)
    }
  })
})

describe('PapersScreen offline truth', () => {
  it('cold-hit offline paints the CACHED list with the stale badge (mutant: delete-the-cache-read)', async () => {
    writeCachedPaperList(conn, listPage(['Alpha Paper', 'Beta Paper']))
    mockFetchPage.mockRejectedValue(OFFLINE())
    const tree = await mountList()
    try {
      const text = textOf(tree)
      expect(text).toContain('Alpha Paper')
      expect(text).toContain('Beta Paper')
      expect(text).toContain('Cached list')
      expect(text).not.toContain(PAPERS_OFFLINE_COPY)
    } finally {
      await unmount(tree)
    }
  })

  it('fresh network clears the badge and write-throughs the list row (mutants: prefer-cache-always, drop-the-write)', async () => {
    writeCachedPaperList(conn, listPage(['Old Cached Row']))
    mockFetchPage.mockResolvedValue(listPage(['Fresh Network Row']))
    const tree = await mountList()
    try {
      const text = textOf(tree)
      expect(text).toContain('Fresh Network Row')
      expect(text).not.toContain('Old Cached Row')
      expect(text).not.toContain('Cached list')
      const row = db
        .prepare(`SELECT payload FROM client_cache WHERE kind = 'paper-list' AND cache_key = 'production'`)
        .get() as { payload: string }
      expect(row.payload).toContain('Fresh Network Row')
    } finally {
      await unmount(tree)
    }
  })

  it('pull-to-refresh with live content never repaints the cache (mutant: paint-cache-over-ready)', async () => {
    // Review guard: the read-through paint is LOADING-phase only. A refresh
    // re-runs the load effect with live content on screen; repainting the
    // cached page-0 over it would flash the stale badge, kill the spinner
    // early, and collapse loaded pages. Mutant: drop the phase guard on the
    // cache paint → the badge appears here and this probe reds.
    mockFetchPage.mockResolvedValue(listPage(['Live Row']))
    const tree = await mountList()
    try {
      expect(textOf(tree)).toContain('Live Row')
      // Refresh while offline: the effect re-runs with a warm cache row (the
      // write-through just stored 'Live Row') and a rejecting network.
      mockFetchPage.mockRejectedValue(OFFLINE())
      const refreshControl = tree.root.findByProps({ refreshing: false })
      await act(async () => {
        refreshControl.props.onRefresh()
      })
      const text = textOf(tree)
      expect(text).toContain('Live Row') // the live list stands
      expect(text).not.toContain('Cached list') // no stale-badge flash over live content
      expect(text).not.toContain(PAPERS_OFFLINE_COPY) // and no error blank either
    } finally {
      await unmount(tree)
    }
  })

  it('cold-miss offline copy is DISTINCT from the failure copy (mutant: collapse-the-messages)', async () => {
    mockFetchPage.mockRejectedValue(OFFLINE())
    const offlineTree = await mountList()
    let offlineText: string
    try {
      offlineText = textOf(offlineTree)
      expect(offlineText).toContain(PAPERS_OFFLINE_COPY)
      expect(offlineText).not.toContain(PAPERS_FAILED_COPY)
    } finally {
      await unmount(offlineTree)
    }

    mockFetchPage.mockRejectedValue(SERVER())
    const failedTree = await mountList()
    try {
      const failedText = textOf(failedTree)
      expect(failedText).toContain(PAPERS_FAILED_COPY)
      expect(failedText).not.toContain(PAPERS_OFFLINE_COPY)
      expect(failedText).not.toBe(offlineText)
    } finally {
      await unmount(failedTree)
    }
  })
})
