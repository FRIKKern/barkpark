// UI truth for the five-state stream vocabulary (charter D24, t3w2-s6):
// the header label map (raw enum strings never reach the UI), the actionable
// refused wall, the Tasks tab's stale-board affordance, and the rollup
// badge's connection-identity invalidation (polish AC4b). All pure functions —
// jest-provable without a native host.
import type { StreamStatus } from '../src/api/chat'
import { rollupFor } from '../src/chat/useChatRollup'
import type { ChatRollup } from '../src/chat/wire'
import type { InstanceConnection } from '../src/api/instance'
import { headerStatus } from '../src/screens/ChatSessionScreen'
import { staleBoardNotice } from '../src/screens/TasksScreen'

// ChatSessionScreen now renders assistant turns through the PortableDoc block
// registry, which reaches MermaidIsland → react-native-webview: a native
// TurboModule with no jest mock of its own. This suite only exercises pure
// functions, so the null stub is honest (the same one paperRenderer uses).
jest.mock('react-native-webview', () => ({ WebView: () => null }))

const ALL_STATUSES: StreamStatus[] = ['connecting', 'open', 'degraded', 'refused', 'closed']

test('the header label map covers all five states and never leaks the raw enum', () => {
  expect(headerStatus('connecting')).toEqual({ text: 'connecting…', tone: 'muted' })
  expect(headerStatus('degraded')).toEqual({ text: 'reconnecting…', tone: 'muted' })
  // Silence is the healthy state — open and closed render nothing.
  expect(headerStatus('open')).toBeUndefined()
  expect(headerStatus('closed')).toBeUndefined()

  // The classifier law: no rendered label is ever the raw enum string.
  for (const status of ALL_STATUSES) {
    const label = headerStatus(status, { class: 'refused', httpStatus: 500, message: 'x' })
    if (label !== undefined) {
      expect(label.text).not.toBe(status)
    }
  }
})

test('refused is actionable and names WHICH wall (401/403 re-auth, 404 back, other retry)', () => {
  for (const httpStatus of [401, 403]) {
    expect(headerStatus('refused', { class: 'refused', httpStatus, message: 'x' })).toEqual({
      text: 'signed out — sign in again',
      tone: 'danger',
      action: 'retry', // retry() builds a fresh store — the re-auth flow
    })
  }
  expect(headerStatus('refused', { class: 'refused', httpStatus: 404, message: 'x' })).toEqual({
    text: 'session gone',
    tone: 'danger',
    action: 'back',
  })
  expect(headerStatus('refused', { class: 'refused', httpStatus: 422, message: 'x' })).toEqual({
    text: 'connection refused — tap to retry',
    tone: 'danger',
    action: 'retry',
  })
  // No failure detail at all → still actionable, never a dead label.
  expect(headerStatus('refused')).toEqual({
    text: 'connection refused — tap to retry',
    tone: 'danger',
    action: 'retry',
  })
})

test('the stale-board affordance shows ONLY on a painted board with a dead stream', () => {
  expect(staleBoardNotice('ready', true)).toBe(
    'Live updates paused — the board may be stale. Tap to refresh.',
  )
  // A live board carries no banner…
  expect(staleBoardNotice('ready', false)).toBeUndefined()
  // …and loading/error screens carry their own honesty already.
  expect(staleBoardNotice('loading', true)).toBeUndefined()
  expect(staleBoardNotice('error', true)).toBeUndefined()
})

test("rollupFor is identity-keyed: a previous connection's badge never survives a reconnect (AC4b)", () => {
  const serverA: InstanceConnection = {
    projectUrl: 'https://a.example',
    token: 't-a',
    dataset: 'production',
  }
  const serverB: InstanceConnection = {
    projectUrl: 'https://b.example',
    token: 't-b',
    dataset: 'production',
  }
  const rollup: ChatRollup = {
    counts: { working: 0, blocked: 2, idle: 1, unknown: 0 },
    precedence: 'blocked',
  }

  // The badge renders for the connection its rollup was fetched from…
  expect(rollupFor(serverA, { connection: serverA, rollup })).toBe(rollup)
  // …and is invalidated the INSTANT the connection identity changes — the
  // previous server's blocked-count never lights the new server's tab.
  expect(rollupFor(serverB, { connection: serverA, rollup })).toBeUndefined()
  // Disconnected → no badge; nothing fetched yet → no badge.
  expect(rollupFor(undefined, { connection: serverA, rollup })).toBeUndefined()
  expect(rollupFor(serverA, undefined)).toBeUndefined()
})
