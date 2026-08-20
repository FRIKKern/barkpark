// CALL-SITE PINS for the D42 per-instance cache clear (task-823028c15c14415b).
//
// The papers-cache wave shipped `CacheStore.clearInstance` and proved it over
// real SQL (papersCache.test.ts, "clearInstance drops one instance and leaves
// the other"). That is the MECHANISM, and a mechanism with no caller is dead
// code: nothing in the shell dropped a departing instance's rows, so a
// signed-out Barkpark's papers stayed on the device and would have painted
// again for whoever signed in next on that phone.
//
// So these probes drive the REAL App shell — the real ConnectScreen inside it,
// the real "Sign out" press, the real fleet auto-connect — over a REAL sqlite
// cache (node:sqlite through the SqlDriver seam), and then re-mount the REAL
// PapersScreen on the departed instance to prove the PAINT is gone, not just a
// row count. The network layer and the Cloud control plane are the only mocks.
//
// NAMED MUTANTS each probe kills (a probe no mutant reds is decoration):
//   • delete-the-clear-in-clearConfig     → the sign-out probes red: the
//     departed instance's row survives AND paints on the next cold hit
//   • delete-the-clear-in-rememberAndSave → the server-switch probe reds
//   • clear-unconditionally (drop the `arriving` compare) → the re-connect
//     probe reds: a plain reconnect would wipe the cache it just filled
//   • clear-the-whole-table (clearInstance → a blanket DELETE) → the
//     other-instance-survives assertions red
//   • delete-the-try (unguard the clear) → the throwing-driver probe reds:
//     a broken cache would throw out of onSignOut and strand the user
//
// TEARDOWN IS LOAD-BEARING (the sibling wiring suites' law): every mount
// unmounts in a finally, under fake timers.
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'

import App from '../App'
import { createCloudClient, type CloudBarkpark } from '../src/cloud/api'
import type { InstanceConnection } from '../src/api/instance'
import { PaperRequestError, fetchPaperPage, type PaperPage } from '../src/api/papers'
import {
  CacheStore,
  instanceCacheKey,
  setCacheForTesting,
  writeCachedPaperList,
  type SqlDriver,
} from '../src/state/cache'
import { clearConfig, loadConfig, rememberAndSave, saveConfig } from '../src/state/appConfig'
import { setStorageForTesting } from '../src/state/storage'
import { PAPERS_OFFLINE_COPY, PapersScreen } from '../src/screens/PapersScreen'

// (hoisted) Only the network / control plane are mocked; every state module,
// screen and the shell itself are real.
jest.mock('../src/api/papers', () => ({
  ...jest.requireActual('../src/api/papers'),
  fetchPaper: jest.fn(),
  fetchPaperPage: jest.fn(),
}))
jest.mock('../src/api/instance', () => ({
  ...jest.requireActual('../src/api/instance'),
  fetchPrimeBrief: jest.fn(() => Promise.resolve({ inProgress: [], ready: [], counts: {}, help: [] })),
}))
jest.mock('../src/api/chat', () => ({
  ...jest.requireActual('../src/api/chat'),
  fetchChatRollup: jest.fn(() => Promise.resolve({ counts: { blocked: 0 }, state: 'idle' })),
  listChatSessions: jest.fn(() => Promise.resolve([])),
  streamFleetEvents: jest.fn(() => new Promise(() => {})),
}))
jest.mock('../src/cloud/api', () => ({
  ...jest.requireActual('../src/cloud/api'),
  createCloudClient: jest.fn(),
}))
jest.mock('react-native-webview', () => ({ WebView: () => null }))
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

const mockFetchPage = fetchPaperPage as jest.Mock
const mockCloudClient = createCloudClient as jest.Mock

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

function freshCache(): void {
  db = new DatabaseSync(':memory:')
  let clock = 1_000_000
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
  setCacheForTesting(new CacheStore(driver, () => ++clock))
}

/** Rows left for one instance — the SQL half of the claim. */
function rowsFor(projectUrl: string): number {
  const row = db
    .prepare(`SELECT COUNT(*) AS n FROM client_cache WHERE instance_id = ?`)
    .get(instanceCacheKey(projectUrl)) as { n: number }
  return row.n
}

/* ── the two instances ──────────────────────────────────────────────────────── */

const A = 'https://a.example'
const B = 'https://b.example'
const CLOUD = 'https://api.barkpark.cloud'

const connTo = (projectUrl: string): InstanceConnection => ({
  projectUrl,
  token: 'tkn',
  dataset: 'production',
})

const OFFLINE = (): PaperRequestError => new PaperRequestError('network request failed', 'offline')

function listPage(titles: string[]): PaperPage {
  return {
    items: titles.map((t, i) => ({ _id: `id-${i}`, title: t, _updatedAt: '2026-07-20T10:00:00Z' })),
    pageLen: titles.length,
    hasMore: false,
  }
}

/* ── the shell state a sign-out is actually reached from ────────────────────── */

/**
 * A Cloud session plus a remembered active server whose instance token is gone
 * — the state a revoked/expired instance token leaves behind, and the ONLY
 * state the app's single sign-out affordance (ConnectScreen's "Sign out") is
 * reachable from: `connectionFromConfig` returns undefined without a token, so
 * App routes to ConnectScreen while `config.server` still names the instance
 * whose rows are on disk. That instance is the "departing" one.
 */
function seedSessionWithRememberedServer(server: string): void {
  saveConfig({
    cloudUrl: CLOUD,
    cloudToken: 'cloud-tok',
    cloudTeam: 'team-1',
    server,
    token: '',
    dataset: 'production',
    knownServers: [{ server, name: 'remembered', dataset: 'production' }],
  })
}

/** A fleet of exactly `list` — n==1 auto-connects with no picker (D14). */
function cloudFleet(list: CloudBarkpark[], credentials?: { url: string; adminToken: string }): void {
  mockCloudClient.mockReturnValue({
    deviceStart: jest.fn(),
    devicePoll: jest.fn(),
    listAllBarkparks: jest.fn(() => Promise.resolve(list)),
    getCredentialsForTeam: jest.fn(() =>
      Promise.resolve({ adminToken: credentials?.adminToken ?? '', url: credentials?.url ?? '', host: '' }),
    ),
    mintAppToken: jest.fn(() => Promise.resolve({ kind: 'unsupported' })),
  })
}

const barkpark = (id: string, url: string): CloudBarkpark => ({
  id,
  name: id,
  url,
  host: '',
  team: { id: 'team-1', name: 'Team', role: 'owner' },
})

/* ── mounting ───────────────────────────────────────────────────────────────── */

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

async function mountApp(): Promise<ReactTestRenderer> {
  let tree: ReactTestRenderer
  await act(async () => {
    tree = create(<App />)
  })
  return tree!
}

async function mountPapers(projectUrl: string): Promise<ReactTestRenderer> {
  let tree: ReactTestRenderer
  await act(async () => {
    tree = create(<PapersScreen connection={connTo(projectUrl)} />)
  })
  return tree!
}

async function unmount(tree: ReactTestRenderer): Promise<void> {
  await act(async () => {
    tree.unmount()
  })
}

/** Text painted by one instance's subtree. `.children` descends only downward,
 * so unlike JSON.stringify on props it cannot meet a parent back-reference. */
function textOfInstance(inst: ReactTestInstance): string {
  const out: string[] = []
  const walk = (n: ReactTestInstance | string): void => {
    if (typeof n === 'string') {
      out.push(n)
      return
    }
    for (const child of n.children) walk(child)
  }
  walk(inst)
  return out.join(' ')
}

/** The one Pressable whose own subtree paints `label` — the real affordance. */
function pressableWithText(tree: ReactTestRenderer, label: string): ReactTestInstance {
  const hits = tree.root.findAll(
    (n: ReactTestInstance) =>
      n.props.accessibilityRole === 'button' && textOfInstance(n).includes(label),
    { deep: false },
  )
  if (hits[0] === undefined) throw new Error(`no "${label}" button in the mounted tree`)
  return hits[0]
}

/** What a cold open of `projectUrl` PAINTS with the network down. */
async function coldOpenOffline(projectUrl: string): Promise<string> {
  mockFetchPage.mockRejectedValue(OFFLINE())
  const tree = await mountPapers(projectUrl)
  try {
    return textOf(tree)
  } finally {
    await unmount(tree)
  }
}

beforeEach(() => {
  jest.useFakeTimers()
  mockFetchPage.mockReset()
  mockCloudClient.mockReset()
  cloudFleet([])
  setStorageForTesting(undefined) // a clean MMKV-shaped slate per probe
  freshCache()
})

afterEach(() => {
  setCacheForTesting(undefined)
  setStorageForTesting(undefined)
  jest.clearAllTimers()
  jest.useRealTimers()
})

/* ── logout ─────────────────────────────────────────────────────────────────── */

describe('sign-out clears the departing instance (mounted App)', () => {
  it('a logged-out instance cold-hit no longer paints its cached papers', async () => {
    writeCachedPaperList(connTo(A), listPage(['Alpha Paper']))
    seedSessionWithRememberedServer(A)

    // BASELINE — the cache is warm and it really does paint. Without this leg
    // the "gone" assertion below could pass on a cache that never worked.
    const before = await coldOpenOffline(A)
    expect(before).toContain('Alpha Paper')
    expect(before).toContain('Cached list')
    expect(rowsFor(A)).toBe(1)

    // THE REAL AFFORDANCE: ConnectScreen's "Sign out", inside the real App.
    const app = await mountApp()
    try {
      await act(async () => {
        pressableWithText(app, 'Sign out').props.onPress()
      })
      // the shell fell back to the login gate — the press really signed out
      expect(textOf(app)).toContain('sign in with Barkpark Cloud')
      expect(loadConfig()).toEqual({})
    } finally {
      await unmount(app)
    }

    // MUTANT KILLED (delete-the-clear-in-clearConfig): the row survives and
    // the next cold hit paints "Alpha Paper" for whoever holds the phone next.
    expect(rowsFor(A)).toBe(0)
    const after = await coldOpenOffline(A)
    expect(after).not.toContain('Alpha Paper')
    expect(after).not.toContain('Cached list')
    expect(after).toContain(PAPERS_OFFLINE_COPY) // an honest cold miss, not a blank
  })

  it('clears ONLY the departing instance — another Barkpark keeps its cache', async () => {
    writeCachedPaperList(connTo(A), listPage(['Alpha Paper']))
    writeCachedPaperList(connTo(B), listPage(['Beta Paper']))
    seedSessionWithRememberedServer(A)

    const app = await mountApp()
    try {
      await act(async () => {
        pressableWithText(app, 'Sign out').props.onPress()
      })
    } finally {
      await unmount(app)
    }

    // MUTANT KILLED (clear-the-whole-table): B is a different account's — or
    // the same user's other — Barkpark, and signing out of A says nothing
    // about it.
    expect(rowsFor(A)).toBe(0)
    expect(rowsFor(B)).toBe(1)
    expect(await coldOpenOffline(B)).toContain('Beta Paper')
  })

  it('signing out with nothing connected is a no-op, not a blanket wipe', async () => {
    writeCachedPaperList(connTo(A), listPage(['Alpha Paper']))
    saveConfig({ cloudUrl: CLOUD, cloudToken: 'cloud-tok' }) // no active server
    clearConfig()
    expect(rowsFor(A)).toBe(1)
    expect(await coldOpenOffline(A)).toContain('Alpha Paper')
  })

  it('a throwing cache never wedges the sign-out (mutant: delete-the-try)', () => {
    const exploding: SqlDriver = {
      exec: () => {},
      run: (sql) => {
        if (sql.startsWith('DELETE FROM client_cache WHERE instance_id = ?')) {
          throw new Error('disk I/O error')
        }
      },
      first: () => undefined,
    }
    setCacheForTesting(new CacheStore(exploding))
    seedSessionWithRememberedServer(A)
    expect(() => clearConfig()).not.toThrow()
    expect(loadConfig()).toEqual({}) // credentials went first, unconditionally
  })
})

/* ── server switch ──────────────────────────────────────────────────────────── */

describe('a server switch clears the instance it left (mounted App)', () => {
  it('auto-connecting to another Barkpark drops the departing one and keeps the arriving one', async () => {
    writeCachedPaperList(connTo(A), listPage(['Alpha Paper']))
    writeCachedPaperList(connTo(B), listPage(['Beta Paper']))
    seedSessionWithRememberedServer(A)
    // One Barkpark in the fleet → ConnectScreen auto-connects, no picker (D14).
    cloudFleet([barkpark('bee', B)], { url: B, adminToken: 'tok-b' })

    const app = await mountApp()
    try {
      // the shell really landed on B: the connected tab bar is up
      expect(textOf(app)).toContain('Papers')
      expect(loadConfig().server).toBe(B)
      expect(loadConfig().token).toBe('tok-b')
    } finally {
      await unmount(app)
    }

    // MUTANT KILLED (delete-the-clear-in-rememberAndSave): A's rows outlive
    // the switch and paint the moment the user switches back.
    expect(rowsFor(A)).toBe(0)
    expect(await coldOpenOffline(A)).not.toContain('Alpha Paper')
    // …and the instance we ARRIVED at keeps its read-through cache: the switch
    // is a per-instance clear, not a cache reset.
    expect(rowsFor(B)).toBe(1)
    expect(await coldOpenOffline(B)).toContain('Beta Paper')
  })

  it('a plain RE-connect keeps the cache — url drift is not a switch (mutant: clear-unconditionally)', () => {
    writeCachedPaperList(connTo(A), listPage(['Alpha Paper']))
    saveConfig({ cloudUrl: CLOUD, cloudToken: 'cloud-tok', server: A, token: 'old', dataset: 'production' })

    // Same instance, arriving with trailing-slash + casing drift: the
    // normalized instance key is unchanged, so the cache it just filled stays.
    rememberAndSave({ server: 'https://A.example/', token: 'fresh', dataset: 'production' })
    expect(instanceCacheKey('https://A.example/')).toBe(instanceCacheKey(A))
    expect(rowsFor(A)).toBe(1)
  })

  it('the FIRST connect of a session clears nothing — there is no departing instance', () => {
    writeCachedPaperList(connTo(A), listPage(['Alpha Paper']))
    saveConfig({ cloudUrl: CLOUD, cloudToken: 'cloud-tok' }) // signed in, never connected
    rememberAndSave({ server: A, token: 'tok-a', dataset: 'production' })
    // Reopening onto the server you left must still be a warm cache — the
    // clear is bound to DEPARTURE, not to connecting.
    expect(rowsFor(A)).toBe(1)
  })
})
