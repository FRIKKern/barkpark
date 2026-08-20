// The needs-you badge and the push verdict must not claim state the app never
// confirmed (mob-lm-s2).
//
// TWO probe-proven violations on origin/main, and each half of this suite kills
// one of them:
//
//   (A) useChatRollup swallowed EVERY failed 60s poll into a bare catch and
//       kept the last-known badge with no age and no failure count. Five dead
//       polls painted `counts.blocked = 3` in the same alarm-red as a count
//       fetched a second ago — the app's only zero-signal cached paint, next to
//       three siblings that all say so (PapersScreen's cached-age badge,
//       TasksScreen's stale-board banner, ChatScreen's live-off line).
//   (B) registerDevice computes an exemplary verdict — it refuses to report
//       `registered` on a 2xx whose body has no id — and App.tsx threw it away.
//       Masked today only because the not_configured adapter always answers
//       `unavailable`; the moment the push-credentials human gate opens, a real
//       401/422/429 is silent.
//
// NAMED MUTANTS these probes kill (a probe no mutant reds is decoration):
//   • restore the bare catch (drop the failures counter) → the hook probes red
//   • flip the comparison in badgeFreshness (`>=` → `>`) → the boundary probes
//     red at exactly STALE_AFTER_POLLS
//   • hard-code the implementation's threshold away from STALE_AFTER_POLLS
//     → every relational probe reds (they ask the exported constant, never a
//     copy of the number)
//   • widen STALE_AFTER_POLLS to an hour → the BOUND probe reds: the badge may
//     not claim to be current for longer than five poll periods
//   • drop the age arm (failures only) → the frozen-timer probe reds
//   • paint the unconfirmed badge with the confirmed fill → the paint probes
//     red (fill, glyph colour and screen-reader line are all asserted DIFFERENT
//     from the confirmed pair, never against a literal hex)
//   • collapse TabBar's badge back to a bare number, or App back to an int →
//     the mounted-shell probe reds: the staleness never reaches the screen
//   • drop `pushNotice(...)` at the App call site → the push-line probe reds
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'

import App from '../App'
import {
  POLL_MS,
  STALE_AFTER_POLLS,
  badgeFreshness,
  useChatRollup,
  type RollupFeed,
} from '../src/chat/useChatRollup'
import type { InstanceConnection } from '../src/api/instance'
import { fetchChatRollup } from '../src/api/chat'
import { pushNotice } from '../src/push'
import { TabBar, badgeLabel } from '../src/ui/TabBar'
import { light } from '../src/ui/theme'
import { saveConfig } from '../src/state/appConfig'
import { setStorageForTesting } from '../src/state/storage'

jest.mock('../src/api/chat', () => ({
  ...jest.requireActual('../src/api/chat'),
  fetchChatRollup: jest.fn(),
  listChatSessions: jest.fn(() => Promise.resolve([])),
  streamFleetEvents: jest.fn(() => new Promise(() => {})),
}))
jest.mock('../src/api/instance', () => ({
  ...jest.requireActual('../src/api/instance'),
  fetchPrimeBrief: jest.fn(() => Promise.resolve({ inProgress: [], ready: [], counts: {}, help: [] })),
}))
jest.mock('react-native-webview', () => ({ WebView: () => null }))
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

const mockRollup = fetchChatRollup as jest.Mock

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example',
  token: 'tkn',
  dataset: 'production',
}

const rollupOf = (blocked: number) => ({
  counts: { working: 0, blocked, idle: 0, unknown: 0 },
  precedence: blocked > 0 ? 'blocked' : 'idle',
})

/* ── (A1) the rule itself, in RELATIONAL terms ─────────────────────────────── */

describe('badgeFreshness — the freshness rule', () => {
  it('flips at the threshold, asked as a relationship rather than as a number', () => {
    // Every leg reads STALE_AFTER_POLLS: change the product choice and these
    // stay true; change the IMPLEMENTATION so it no longer flips there and
    // they red.
    expect(badgeFreshness(0, 0)).toBe('confirmed')
    expect(badgeFreshness(STALE_AFTER_POLLS - 1, 0)).toBe('confirmed')
    expect(badgeFreshness(STALE_AFTER_POLLS, 0)).toBe('unconfirmed')
    expect(badgeFreshness(STALE_AFTER_POLLS + 7, 0)).toBe('unconfirmed')
  })

  it('goes unconfirmed on AGE alone — a frozen poll reports no failures at all', () => {
    const window = STALE_AFTER_POLLS * POLL_MS
    expect(badgeFreshness(0, window - 1)).toBe('confirmed')
    expect(badgeFreshness(0, window)).toBe('unconfirmed')
  })

  it('a count that never landed is not aged out — there is nothing to age', () => {
    // No confirmed answer yet means no rollup and therefore no badge; the age
    // arm must not manufacture an "unconfirmed" verdict out of undefined.
    expect(badgeFreshness(0, undefined)).toBe('confirmed')
    // …but failures still count, because a failing poll IS evidence.
    expect(badgeFreshness(STALE_AFTER_POLLS, undefined)).toBe('unconfirmed')
  })

  it('BOUND: the badge may never claim to be current for more than five polls', () => {
    // The threshold is an unratified product choice, so it is not pinned to a
    // literal here — but the PROMISE is bounded: at least one poll of grace
    // (one blip must not cry stale) and at most five (≈5min), past which "3
    // sessions need you" would be a claim, not a reading.
    expect(STALE_AFTER_POLLS).toBeGreaterThanOrEqual(1)
    expect(STALE_AFTER_POLLS).toBeLessThanOrEqual(5)
  })
})

/* ── (A2) the hook: failed polls are COUNTED, not swallowed ────────────────── */

/** A headless probe: render the feed, capture it, paint nothing. */
function Probe({
  connection,
  now,
  sink,
}: {
  connection: InstanceConnection | undefined
  now: () => number
  sink: (f: RollupFeed) => void
}) {
  sink(useChatRollup(connection, now))
  return null
}

describe('useChatRollup — the feed carries what it knows', () => {
  let clock = 0
  let feeds: RollupFeed[]

  const last = (): RollupFeed => feeds[feeds.length - 1]!

  beforeEach(() => {
    jest.useFakeTimers()
    clock = 1_000_000
    feeds = []
    mockRollup.mockReset()
  })

  afterEach(() => {
    jest.clearAllTimers()
    jest.useRealTimers()
  })

  // NOT a defaulted parameter: `mount(undefined)` would silently take the
  // default and mount the CONNECTED case, quietly turning the disconnected
  // probe into a duplicate of its neighbour.
  async function mount(connection: InstanceConnection | undefined): Promise<ReactTestRenderer> {
    let tree: ReactTestRenderer
    await act(async () => {
      tree = create(<Probe connection={connection} now={() => clock} sink={(f) => feeds.push(f)} />)
    })
    return tree!
  }

  /** One poll period, with the clock moved to match. */
  async function poll(): Promise<void> {
    clock += POLL_MS
    await act(async () => {
      jest.advanceTimersByTime(POLL_MS)
    })
  }

  it('a landed rollup is confirmed, with zero failures', async () => {
    mockRollup.mockResolvedValue(rollupOf(3))
    const tree = await mount(conn)
    try {
      expect(last().rollup?.counts.blocked).toBe(3)
      expect(last().freshness).toBe('confirmed')
      expect(last().failures).toBe(0)
      expect(last().ageMs).toBe(0)
    } finally {
      await act(async () => tree.unmount())
    }
  })

  it('keeps the last-known count through dead polls — and stops calling it confirmed', async () => {
    mockRollup.mockResolvedValueOnce(rollupOf(3))
    mockRollup.mockRejectedValue(new Error('offline'))
    const tree = await mount(conn)
    try {
      expect(last().freshness).toBe('confirmed')

      // One blip: the count stands AND still counts as a reading (the badge
      // must not flicker on a single lost race with a screen lock).
      await poll()
      expect(last().rollup?.counts.blocked).toBe(3)
      expect(last().failures).toBe(1)
      if (STALE_AFTER_POLLS > 1) expect(last().freshness).toBe('confirmed')

      // Past the threshold: the number is STILL on screen — a dead rollup does
      // not take the tab bar down — but the app has stopped vouching for it.
      for (let i = last().failures; i < STALE_AFTER_POLLS; i++) await poll()
      expect(last().rollup?.counts.blocked).toBe(3)
      expect(last().failures).toBeGreaterThanOrEqual(STALE_AFTER_POLLS)
      expect(last().freshness).toBe('unconfirmed')
    } finally {
      await act(async () => tree.unmount())
    }
  })

  it('a recovered poll clears the doubt — freshness is not a one-way latch', async () => {
    mockRollup.mockRejectedValue(new Error('offline'))
    const tree = await mount(conn)
    try {
      for (let i = 0; i < STALE_AFTER_POLLS; i++) await poll()
      expect(last().freshness).toBe('unconfirmed')

      mockRollup.mockResolvedValue(rollupOf(1))
      await poll()
      expect(last().rollup?.counts.blocked).toBe(1)
      expect(last().failures).toBe(0)
      expect(last().freshness).toBe('confirmed')
    } finally {
      await act(async () => tree.unmount())
    }
  })

  it('age is read at RENDER time, so a frozen interval cannot keep a count fresh', async () => {
    mockRollup.mockResolvedValue(rollupOf(2))
    const tree = await mount(conn)
    try {
      expect(last().freshness).toBe('confirmed')
      // The app was suspended: wall-clock time passed, the interval never
      // fired, so there are ZERO failures to count. Only the age arm can catch
      // this, and it must catch it on the very first paint after resume.
      clock += STALE_AFTER_POLLS * POLL_MS
      await act(async () => {
        tree.update(<Probe connection={conn} now={() => clock} sink={(f) => feeds.push(f)} />)
      })
      expect(last().failures).toBe(0)
      expect(last().ageMs).toBeGreaterThanOrEqual(STALE_AFTER_POLLS * POLL_MS)
      expect(last().freshness).toBe('unconfirmed')
    } finally {
      await act(async () => tree.unmount())
    }
  })

  it('a disconnected app carries no badge and no inherited doubt', async () => {
    mockRollup.mockRejectedValue(new Error('offline'))
    const tree = await mount(undefined)
    try {
      expect(last().rollup).toBeUndefined()
      expect(last().failures).toBe(0)
      expect(last().ageMs).toBeUndefined()
    } finally {
      await act(async () => tree.unmount())
    }
  })
})

/* ── (A3) the paint: the two badges must not look the same ─────────────────── */

describe('TabBar — the unconfirmed badge paints as last-known', () => {
  function bar(badge: { count: number; confirmed?: boolean }): ReactTestRenderer {
    let tree: ReactTestRenderer
    act(() => {
      tree = create(<TabBar active="tasks" onSelect={() => {}} badges={{ chat: badge }} />)
    })
    return tree!
  }

  /** The badge chip itself — found by the label it announces. */
  function chip(tree: ReactTestRenderer, count: number, confirmed: boolean): ReactTestInstance {
    return tree.root.find(
      (n: ReactTestInstance) => n.props.accessibilityLabel === badgeLabel('Chat', count, confirmed),
    )
  }

  function flatten(style: unknown): Record<string, unknown> {
    const out: Record<string, unknown> = {}
    const walk = (s: unknown): void => {
      if (Array.isArray(s)) {
        for (const part of s) walk(part)
      } else if (s !== null && typeof s === 'object') {
        Object.assign(out, s as Record<string, unknown>)
      }
    }
    walk(style)
    return out
  }

  it('differs from the confirmed badge in FILL and in GLYPH COLOUR', () => {
    const fresh = bar({ count: 3, confirmed: true })
    const stale = bar({ count: 3, confirmed: false })
    try {
      const freshChip = flatten(chip(fresh, 3, true).props.style)
      const staleChip = flatten(chip(stale, 3, false).props.style)

      // The RELATIONSHIP, not the hex: whatever the theme says, the two states
      // must not be the same chip. (Both legs also prove the theme is actually
      // consulted — an undefined fill would trivially satisfy `not.toBe`.)
      expect(freshChip.backgroundColor).toBe(light.danger)
      expect(staleChip.backgroundColor).toBe(light.warnSoft)
      expect(staleChip.backgroundColor).not.toBe(freshChip.backgroundColor)
      // …and the unconfirmed chip carries the outline the soft fill needs to
      // stay legible as a chip at all.
      expect(staleChip.borderWidth).toBeGreaterThan(0)

      const freshText = flatten(
        fresh.root.findAllByProps({ children: '3' })[0]!.props.style as unknown,
      )
      const staleText = flatten(
        stale.root.findAllByProps({ children: '3' })[0]!.props.style as unknown,
      )
      expect(staleText.color).not.toBe(freshText.color)
    } finally {
      act(() => fresh.unmount())
      act(() => stale.unmount())
    }
  })

  it('says so out loud: the screen-reader line names the count as last-known', () => {
    expect(badgeLabel('Chat', 3, true)).toBe('Chat: 3 needs you')
    expect(badgeLabel('Chat', 3, false)).toContain('not confirmed')
    expect(badgeLabel('Chat', 3, false)).not.toBe(badgeLabel('Chat', 3, true))
  })

  it('an absent badge is still no badge — unconfirmed is not a way to paint zero', () => {
    const tree = bar({ count: 0, confirmed: false })
    try {
      expect(
        tree.root.findAll(
          (n: ReactTestInstance) =>
            typeof n.props.accessibilityLabel === 'string' &&
            (n.props.accessibilityLabel as string).includes('needs you'),
          { deep: false },
        ),
      ).toHaveLength(0)
    } finally {
      act(() => tree.unmount())
    }
  })
})

/* ── (B) the push verdict ──────────────────────────────────────────────────── */

describe('pushNotice — every non-registered verdict becomes a line', () => {
  it('is silent only for a CONFIRMED registration (and before any verdict)', () => {
    expect(pushNotice(undefined)).toBeUndefined()
    expect(pushNotice({ status: 'registered', id: 'row-1', platform: 'apns' })).toBeUndefined()
  })

  it('covers all six non-registered outcomes, each with its own wording', () => {
    const lines = [
      pushNotice({ status: 'unavailable', reason: 'module-missing' }),
      pushNotice({ status: 'network-error', detail: 'Network request failed' }),
      pushNotice({ status: 'rate-limited' }),
      pushNotice({ status: 'unauthorized' }),
      pushNotice({ status: 'rejected', detail: 'invalid' }),
      pushNotice({ status: 'server-error', httpStatus: 503 }),
    ]
    for (const line of lines) expect(typeof line).toBe('string')
    // Six distinct lines: a single "push failed" for everything would tell the
    // user nothing they could act on.
    expect(new Set(lines).size).toBe(lines.length)
    expect(lines[5]).toContain('503')
  })
})

/* ── the CHANNEL: both signals, through the real mounted shell ─────────────── */

describe('the mounted App shell carries both signals to the screen', () => {
  const CLOUD = 'https://api.barkpark.cloud'

  function seedConnected(): void {
    saveConfig({
      cloudUrl: CLOUD,
      cloudToken: 'cloud-tok',
      cloudTeam: 'team-1',
      server: conn.projectUrl,
      token: conn.token,
      dataset: 'production',
      knownServers: [{ server: conn.projectUrl, name: 'bp', dataset: 'production' }],
    })
  }

  /** Every string leaf the mounted tree paints. */
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

  /** The badge labels the shell is currently announcing. */
  function badgeLabels(tree: ReactTestRenderer): string[] {
    return tree.root
      .findAll(
        (n: ReactTestInstance) =>
          typeof n.props.accessibilityLabel === 'string' &&
          (n.props.accessibilityLabel as string).includes('needs you'),
        // deep:false — a React Native <View> is a composite AND a host node, so
        // an unpruned walk counts the same chip twice.
        { deep: false },
      )
      .map((n) => n.props.accessibilityLabel as string)
  }

  beforeEach(() => {
    jest.useFakeTimers()
    mockRollup.mockReset()
    setStorageForTesting(undefined)
    seedConnected()
  })

  afterEach(() => {
    setStorageForTesting(undefined)
    jest.clearAllTimers()
    jest.useRealTimers()
  })

  it('paints a confirmed badge, then the SAME count as last-known once the poll dies', async () => {
    mockRollup.mockResolvedValueOnce(rollupOf(3))
    mockRollup.mockRejectedValue(new Error('offline'))

    let tree: ReactTestRenderer
    await act(async () => {
      tree = create(<App />)
    })
    try {
      expect(badgeLabels(tree!)).toEqual([badgeLabel('Chat', 3, true)])

      for (let i = 0; i < STALE_AFTER_POLLS; i++) {
        await act(async () => {
          jest.advanceTimersByTime(POLL_MS)
        })
      }

      // MUTANT KILLED: collapse the shell back to `rollup?.counts.blocked ?? 0`
      // (or TabBar back to a bare number) and this flips — the count would be
      // right and the app's confidence in it would vanish on the way to the
      // screen.
      expect(badgeLabels(tree!)).toEqual([badgeLabel('Chat', 3, false)])
    } finally {
      await act(async () => tree!.unmount())
    }
  })

  it('says out loud that push is not registered on this build', async () => {
    mockRollup.mockResolvedValue(rollupOf(0))

    let tree: ReactTestRenderer
    await act(async () => {
      tree = create(<App />)
    })
    try {
      // The REAL registration path runs: `expo-notifications` is deliberately
      // not a dependency, so the OS half answers `unavailable/module-missing`
      // and the shell must render that verdict rather than swallow it.
      expect(textOf(tree!)).toContain(
        pushNotice({ status: 'unavailable', reason: 'module-missing' })!,
      )
    } finally {
      await act(async () => tree!.unmount())
    }
  })
})
