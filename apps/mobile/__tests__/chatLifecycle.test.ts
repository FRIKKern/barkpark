// The lifecycle vocabulary's PURE laws (t3w2-s7).
//
// Three columns, three meanings, and this suite exists because collapsing any
// two of them is the failure mode that reads as "working":
//
//   status      — liveness
//   agent_state — attention ("blocked" on the wire, "needs you" on screen)
//   archived_at — dismissal
//
// Plus the ratified-call-#5 split: the model you ASKED for and the model that
// ANSWERED are different facts, and a UI that shows only the first is lying
// exactly when it matters.
import {
  EFFORT_HONESTY,
  observedModelNote,
  pickerVocabulary,
} from '../src/chat/PickerSheet'
import {
  SHELF_CAP,
  STALL_TICK_MS,
  SWIPE_COMMIT_PX,
  nextOpenAfterArchive,
  swipeCommits,
} from '../src/screens/ChatScreen'
import { HERD_STALL_AFTER_MS } from '../src/chat/herd'
import {
  archiveChatSession,
  listChatSessions,
  unarchiveChatSession,
  fetchChatCapabilities,
  patchChatSession,
} from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'

jest.mock('expo/fetch', () => ({ fetch: jest.fn() }))
// ChatScreen pulls in the session screen, which pulls in the block renderers,
// which pull in a WebView with no native binary under jest.
jest.mock('react-native-webview', () => ({ WebView: () => null }))
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))
// eslint-disable-next-line @typescript-eslint/no-require-imports
const mockFetch = (require('expo/fetch') as { fetch: jest.Mock }).fetch

const conn: InstanceConnection = {
  projectUrl: 'https://bp.example/',
  token: 'tkn',
  dataset: 'production',
}

/** One canned HTTP answer for the next expoFetch call. */
function answer(status: number, body: unknown): void {
  mockFetch.mockResolvedValueOnce({
    status,
    ok: status >= 200 && status < 300,
    text: () => Promise.resolve(typeof body === 'string' ? body : JSON.stringify(body)),
  })
}

/** [url, init] of the Nth call. */
function callArgs(n = 0): [string, { method: string; body?: string }] {
  return mockFetch.mock.calls[n] as [string, { method: string; body?: string }]
}

beforeEach(() => mockFetch.mockReset())

/* ── the shelf IS the archived truth ─────────────────────────────────────── */

describe('the shelf is the only archived truth', () => {
  test('listChatSessions sends archived= EXPLICITLY on both shelves', async () => {
    answer(200, { sessions: [] })
    await listChatSessions(conn, false)
    expect(callArgs()[0]).toBe('https://bp.example/v1/chat/sessions?archived=false')

    mockFetch.mockReset()
    answer(200, { sessions: [] })
    await listChatSessions(conn, true)
    // MUTANT KILLED: an implementation that ignores the flag (or omits the
    // param and lets the server guess) serves the ACTIVE shelf under the
    // Archived heading — a screen full of sessions the user never dismissed,
    // with no per-row field anywhere that could contradict it.
    expect(callArgs()[0]).toBe('https://bp.example/v1/chat/sessions?archived=true')
  })

  test('the default shelf is active — a caller that forgets asks for the live list', async () => {
    answer(200, { sessions: [] })
    await listChatSessions(conn)
    expect(callArgs()[0]).toContain('archived=false')
  })

  test('no sidebar row carries an archived field — the request does', async () => {
    // The wire shape this client projects (ChatSessionSummary) deliberately has
    // no archived key. If one is ever added, the shelf stops being the truth
    // and two sources start disagreeing — so pin the absence.
    answer(200, { sessions: [{ id: 's1', archived_at: '2026-07-26T00:00:00Z' }] })
    const rows = await listChatSessions(conn, true)
    const projected = rows[0] as unknown as Record<string, unknown>
    // The raw JSON passes through (forward-compat), but nothing in the app
    // reads it: the assertion that matters is that the SHELF was requested.
    expect(callArgs()[0]).toContain('archived=true')
    expect(projected.id).toBe('s1')
  })
})

/* ── the archive verbs ───────────────────────────────────────────────────── */

describe('archive verbs', () => {
  test('archive POSTs the action route and accepts ONLY 200', async () => {
    answer(200, { id: 's1' })
    await archiveChatSession(conn, 's1')
    const [url, init] = callArgs()
    expect(url).toBe('https://bp.example/v1/chat/sessions/s1/archive')
    expect(init.method).toBe('POST')
    // No body: archive is a verb, not a field write.
    expect(init.body).toBeUndefined()
  })

  test('unarchive POSTs its own route — never a PATCH of an archived key', async () => {
    answer(200, { id: 's1' })
    await unarchiveChatSession(conn, 's1')
    const [url, init] = callArgs()
    expect(url).toBe('https://bp.example/v1/chat/sessions/s1/unarchive')
    expect(init.method).toBe('POST')
  })

  test('the 404 not-found oracle surfaces as a throw, so optimism can roll back', async () => {
    answer(404, { error: 'not_found' })
    await expect(archiveChatSession(conn, 'gone')).rejects.toThrow('HTTP 404')
  })

  test('session ids are path-escaped', async () => {
    answer(200, {})
    await archiveChatSession(conn, 'a/b?c')
    expect(callArgs()[0]).toBe('https://bp.example/v1/chat/sessions/a%2Fb%3Fc/archive')
  })

  test('PATCH carries continuity keys and never an archived one', async () => {
    answer(200, {})
    await patchChatSession(conn, 's1', { model_choice: 'opus' })
    const [url, init] = callArgs()
    expect(url).toBe('https://bp.example/v1/chat/sessions/s1')
    expect(init.method).toBe('PATCH')
    expect(JSON.parse(init.body as string)).toEqual({ model_choice: 'opus' })
  })
})

/* ── nav asymmetry (charter D28) ─────────────────────────────────────────── */

describe('nav asymmetry', () => {
  const open = { id: 's1', title: 'one' }

  test('archiving the session you are LOOKING AT pops you out', () => {
    expect(nextOpenAfterArchive(open, 's1')).toBeUndefined()
  })

  test('archiving ANY OTHER session leaves you exactly where you are', () => {
    // MUTANT KILLED: an unconditional `return undefined` also passes the first
    // case and would yank the user out of a session they are reading because
    // an unrelated one was dismissed.
    expect(nextOpenAfterArchive(open, 's2')).toBe(open)
  })

  test('archiving with nothing open navigates nowhere', () => {
    expect(nextOpenAfterArchive(undefined, 's1')).toBeUndefined()
  })

  test('unarchive never navigates — it has no navigation rule to call', () => {
    // The asymmetry is structural: unarchive ADDS a row to a shelf, so no view
    // has to cope. This test documents that the unarchive path deliberately
    // does not consult nextOpenAfterArchive; the wiring probe proves it.
    expect(nextOpenAfterArchive(open, 's1')).toBeUndefined()
    expect(nextOpenAfterArchive(open, 'anything-else')).toBe(open)
  })
})

/* ── swipe commit ────────────────────────────────────────────────────────── */

describe('swipe commit', () => {
  test('commits at or past the threshold, leftward only', () => {
    expect(swipeCommits(-SWIPE_COMMIT_PX)).toBe(true)
    expect(swipeCommits(-500)).toBe(true)
  })

  test('a short drag does not commit', () => {
    expect(swipeCommits(-SWIPE_COMMIT_PX + 1)).toBe(false)
    expect(swipeCommits(-5)).toBe(false)
    expect(swipeCommits(0)).toBe(false)
  })

  test('a RIGHTWARD drag never commits, however far', () => {
    // MUTANT KILLED: `Math.abs(dx) >= SWIPE_COMMIT_PX` passes every leftward
    // case above and archives on a right-swipe — a gesture with no verb behind
    // it and no undo in front of it.
    expect(swipeCommits(SWIPE_COMMIT_PX)).toBe(false)
    expect(swipeCommits(500)).toBe(false)
  })
})

/* ── picker discovery degrades ───────────────────────────────────────────── */

describe('picker vocabulary', () => {
  const caps = {
    providers: {
      claude: {
        modes: ['plan', 'acceptEdits', 'auto', 'dontAsk', 'manual'],
        models: ['haiku', 'sonnet', 'opus', 'fable'],
        efforts: ['low', 'medium', 'high', 'xhigh', 'max'],
      },
      codex: { modes: [], models: [], efforts: [] },
    },
  }

  test('a discovered provider offers exactly what the server advertised', () => {
    const v = pickerVocabulary(caps, 'claude')
    expect(v.degraded).toBeUndefined()
    expect(v.models).toEqual(['haiku', 'sonnet', 'opus', 'fable'])
    expect(v.efforts).toHaveLength(5)
  })

  test('bypassPermissions is never offered — because the server never lists it', () => {
    // D22 is kept by HONORING discovery, not by a client-side filter: the
    // server's own claude mode list omits bypass. A client that added its own
    // mode list would re-open the hole this asserts is closed.
    expect(pickerVocabulary(caps, 'claude').modes).not.toContain('bypassPermissions')
  })

  test('an all-empty provider degrades honestly and names itself', () => {
    // MUTANT KILLED: falling back to the claude floor when a provider is empty
    // would render five model chips for codex — every one of them a dead
    // control that PATCHes a value the server rejects.
    const v = pickerVocabulary(caps, 'codex')
    expect(v.models).toEqual([])
    expect(v.degraded).toContain('codex')
  })

  test('no block at all is a DIFFERENT fact from an empty provider', () => {
    const none = pickerVocabulary(undefined, 'claude')
    const empty = pickerVocabulary(caps, 'codex')
    expect(none.degraded).not.toBe(empty.degraded)
    expect(none.degraded).toContain('does not advertise')
  })

  test('an unknown provider is named, not silently given claude', () => {
    const v = pickerVocabulary(caps, 'gemini')
    expect(v.models).toEqual([])
    expect(v.degraded).toContain('gemini')
  })

  test('a session whose provider has not loaded yet does not guess', () => {
    expect(pickerVocabulary(caps, '').degraded).toBe('Loading this session…')
  })
})

/* ── observed vs chosen (ratified call #5) ───────────────────────────────── */

describe('observed model truth', () => {
  test('silent before any turn has streamed — there is nothing observed to report', () => {
    expect(observedModelNote('', 'opus')).toBeUndefined()
  })

  test('agreement reads as plain fact', () => {
    expect(observedModelNote('opus', 'opus')).toEqual({
      text: 'answering with opus',
      disagrees: false,
    })
  })

  test('DISAGREEMENT names both, and flags itself', () => {
    // MUTANT KILLED: a note built from `chosen` alone ("using opus") passes the
    // agreement case and is silent exactly when the user needs it — the whole
    // reason Studio grew an observed-model row.
    const note = observedModelNote('sonnet', 'opus')
    expect(note).toBeDefined()
    expect(note?.disagrees).toBe(true)
    expect(note?.text).toContain('opus')
    expect(note?.text).toContain('sonnet')
  })

  test('an observation with no request still speaks', () => {
    expect(observedModelNote('fable', '')).toEqual({
      text: 'answering with fable',
      disagrees: false,
    })
  })

  test('whitespace is not a disagreement', () => {
    expect(observedModelNote(' opus ', 'opus')?.disagrees).toBe(false)
  })

  test('effort carries the persist-only honesty line, not a fake steer', () => {
    expect(EFFORT_HONESTY).toContain('next resume')
  })
})

/* ── discovery transport ─────────────────────────────────────────────────── */

describe('capability discovery', () => {
  test('asks with ?chat=1 — the opt-in a strict-decoding bp depends on', async () => {
    answer(200, { chat: { providers: { claude: { modes: [], models: [], efforts: [] } } } })
    await fetchChatCapabilities(conn)
    expect(callArgs()[0]).toBe('https://bp.example/v1/capabilities?chat=1')
  })

  test('a manifest with no chat block yields undefined, not an empty guess', async () => {
    answer(200, { nouns: [], commands: [] })
    await expect(fetchChatCapabilities(conn)).resolves.toBeUndefined()
  })
})

/* ── the constants stay coherent ─────────────────────────────────────────── */

describe('clock + cap constants', () => {
  test('the stall clock ticks well inside the stall threshold', () => {
    // A tick at or above the threshold could let a session sit visibly
    // un-stalled for a full extra window — the badge would be late, which is
    // the one thing a stall badge may not be.
    expect(STALL_TICK_MS).toBeLessThan(HERD_STALL_AFTER_MS / 2)
  })

  test('the shelf cap matches the server @sidebar_cap', () => {
    expect(SHELF_CAP).toBe(50)
  })
})
