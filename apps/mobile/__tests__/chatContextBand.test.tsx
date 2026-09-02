// THE CHAT SESSION SCREEN'S CONNECTION HEADER (chat-local-cloud-context-w3,
// criterion 2) — the mobile sibling of internal/chat/context_test.go and of
// Studio's chat_context_band_test.exs.
//
// Every probe here reads the RENDERED BAND, not the resolver's return value and
// not the template: the failure this band exists to prevent is a wrong
// connection reading as a right one ON SCREEN, and a resolver can be perfectly
// correct while the screen paints none of it. So the mounted probes go through
// the REAL ChatSessionScreen over the REAL store, and read the strings the
// device would show.
//
// TWO CONVENTIONS, both load-bearing:
//
//   * BY NAME, NEVER BY POSITION. Every assertion addresses a field through
//     `band(tree)['dataset']`. A positional read of a six-item row passes
//     happily when two fields swap, which is the exact shape of a plumbing bug.
//   * THE MISMATCH MESSAGE NAMES THE FIELD. Each expectation is checked in a
//     loop whose failure message is written before the assertion and carries
//     the field name and both values — a bare `toEqual` on a six-key object
//     prints a diff that makes you hunt for which one moved.
//
// TEARDOWN IS LOAD-BEARING: the store owns a real setInterval, so every mount
// unmounts in a finally (see chatScreenWiring.test.tsx).
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'

import { getChatSession, streamChatEvents, type ChatStreamOptions } from '../src/api/chat'
import type { InstanceConnection } from '../src/api/instance'
import {
  ABSENT_NO_REPO,
  ABSENT_SERVER_LOCAL,
  ABSENT_UNKNOWN,
  ABSENT_UNSET,
  CONTEXT_FIELD_NAMES,
  contextField,
  fieldDisplay,
  resolveContextIdentity,
  type ConnectionClaim,
} from '../src/chat/context'
import { contextSegmentText, MISMATCH_MARK } from '../src/chat/ContextBand'
import type { ChatSessionContext } from '../src/chat/wire'
import { ChatSessionScreen } from '../src/screens/ChatSessionScreen'

// (hoisted by jest above the imports) — every api/chat binding the screen's
// stack reaches must be here; a missing one is a runtime "is not a function"
// inside an effect, not a type error.
jest.mock('../src/api/chat', () => ({
  getChatSession: jest.fn(),
  sendChatMessage: jest.fn(),
  interruptChat: jest.fn(),
  respondChatApproval: jest.fn(),
  streamChatEvents: jest.fn(),
  patchChatSession: jest.fn(() => Promise.resolve()),
  fetchChatCapabilities: jest.fn(() => Promise.resolve(undefined)),
}))
jest.mock('react-native-webview', () => ({ WebView: () => null }))
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

const mockGet = getChatSession as jest.Mock
const mockStream = streamChatEvents as jest.Mock

/** THE LIVE CONNECTION — what the app actually dials. Deliberately NOT equal to
 * the stored claim below on server/workspace/dataset: the whole point of the
 * band is that these two can drift, and a fixture where they agree could not
 * tell a surface reading the connection from one reading the config. */
const conn: InstanceConnection = {
  projectUrl: 'https://live.example',
  token: 'tkn',
  dataset: 'staging',
  workspace: 'acme',
  project: 'site',
}

/** THE STORED CLAIM — the persisted config literal, stale on three fields. */
const claim: ConnectionClaim = {
  server: 'https://stale.example',
  workspace: 'acme',
  project: 'site',
  dataset: 'production',
}

/** The server's facts about the session. The workspace here is NOT the app's:
 * the session is owned by another workspace, which is the "app scope vs session
 * scope" half of the mismatch fixture. */
const wire: ChatSessionContext = {
  host: 'mac-mini-01',
  execution_target: 'registered_host',
  cwd: '/Users/dev/barkpark',
  workspace: 'globex',
  repo_root: null,
  repo_status: 'unknown',
}

let streams: ChatStreamOptions[] = []

beforeEach(() => {
  // Fake timers are TEARDOWN, not speed — see chatScreenWiring.test.tsx.
  jest.useFakeTimers()
  mockGet.mockReset()
  mockStream.mockReset()
  streams = []
  mockStream.mockImplementation((_c: unknown, _id: unknown, opts: ChatStreamOptions) => {
    streams.push(opts)
    return new Promise(() => {}) // a live stream never resolves on its own
  })
})

afterEach(() => {
  jest.clearAllTimers()
  jest.useRealTimers()
})

const live = (): ChatStreamOptions => streams[streams.length - 1]!

async function mount(
  props: { claim?: ConnectionClaim; connection?: InstanceConnection } = {},
): Promise<ReactTestRenderer> {
  let tree: ReactTestRenderer
  await act(async () => {
    tree = create(
      <ChatSessionScreen
        connection={props.connection ?? conn}
        claim={props.claim}
        sessionId="s1"
        onBack={() => {}}
      />,
    )
  })
  return tree!
}

function textOf(node: ReactTestInstance | string): string {
  if (typeof node === 'string') return node
  return node.children.map(textOf).join('')
}

/** THE RENDERED BAND, read off the screen and keyed BY FIELD NAME.
 *
 * It walks by testID rather than by index, and it returns a plain map so a
 * missing field is `undefined` (a loud failure) instead of the sixth segment
 * quietly answering for the fifth. */
function band(tree: ReactTestRenderer): Record<string, string> {
  const out: Record<string, string> = {}
  for (const name of CONTEXT_FIELD_NAMES) {
    const nodes = tree.root.findAll(
      (n: ReactTestInstance) => n.props.testID === `chat-context-${name}`,
      { deep: false },
    )
    if (nodes.length === 1) out[name] = textOf(nodes[0]!)
  }
  return out
}

/** Assert the band, field by field, with a message that NAMES the field and
 * carries both strings. Written before the assertion on purpose: a `toEqual`
 * over the whole map reports "objects differ" and leaves you diffing six lines
 * to find which plumbing was cut. */
function expectBand(actual: Record<string, string>, expected: Record<string, string>): void {
  for (const name of CONTEXT_FIELD_NAMES) {
    const want = expected[name]
    const got = actual[name]
    if (got !== want) {
      throw new Error(
        `context band field "${name}": rendered ${JSON.stringify(got)}, expected ` +
          `${JSON.stringify(want)} — the band's ${name} plumbing is severed or renaming its value`,
      )
    }
  }
  // Nothing EXTRA either: a seventh segment is a field nobody reconciled.
  const rendered = Object.keys(actual).sort()
  const wanted = CONTEXT_FIELD_NAMES.slice().sort()
  expect(rendered).toEqual(wanted)
}

/* ── 1 — the band renders, from the wire and the LIVE connection ───────────── */

test('CRIT 1 — the session screen renders host/server/workspace/project/dataset/repo, from the wire and the live client', async () => {
  mockGet.mockResolvedValue({ id: 's1', messages: [], context: wire })
  const tree = await mount({ claim })
  try {
    expectBand(band(tree), {
      // Server truth: the host holding the live lease.
      host: 'host mac-mini-01',
      // The CONNECTION's endpoint, with the stale stored claim reported.
      server: `${MISMATCH_MARK} server https://live.example — configured "https://stale.example"`,
      // The SESSION's own workspace beats the app's scope, and says so.
      workspace: `${MISMATCH_MARK} workspace globex — the app is scoped to "acme"`,
      project: 'project site',
      // The connection dials staging while the config still says production.
      dataset: `${MISMATCH_MARK} dataset staging — configured "production"`,
      // Nobody can report a work tree on someone else's machine.
      repo: `repo ${ABSENT_UNKNOWN} — "/Users/dev/barkpark" on the execution host, which reports no repository root`,
    })
  } finally {
    await act(async () => tree.unmount())
  }
})

test('CRIT 1 — the displayed server/dataset come from the CONNECTION, never from the stored claim', async () => {
  mockGet.mockResolvedValue({ id: 's1', messages: [], context: wire })
  const tree = await mount({ claim })
  try {
    const rendered = band(tree)
    // The precise failure this law prevents: a band that printed the config
    // would read "https://stale.example" while the app talks to live.example.
    expect(rendered['server']).toContain('https://live.example')
    expect(rendered['server']).not.toMatch(/^\S+ server https:\/\/stale\.example/)
    expect(rendered['dataset']).toContain('dataset staging')
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── 2 — the mismatch fixture, and typed absence ───────────────────────────── */

test('CRIT 2 — every disagreeing field is reported BY NAME with BOTH values', async () => {
  mockGet.mockResolvedValue({ id: 's1', messages: [], context: wire })
  const tree = await mount({ claim })
  try {
    const rendered = band(tree)
    // field -> [the value in force, the value it disagrees with]
    const disagreements: Record<string, [string, string]> = {
      server: ['https://live.example', 'https://stale.example'],
      workspace: ['globex', 'acme'],
      dataset: ['staging', 'production'],
    }
    for (const [name, [inForce, other]] of Object.entries(disagreements)) {
      const seg = rendered[name] ?? ''
      if (!seg.startsWith(`${MISMATCH_MARK} `)) {
        throw new Error(
          `context band field "${name}": rendered ${JSON.stringify(seg)} with no ${MISMATCH_MARK} — ` +
            `it disagrees (${inForce} vs ${other}) and a silent disagreement is how a wrong connection reads as a right one`,
        )
      }
      for (const value of [inForce, other]) {
        if (!seg.includes(value)) {
          throw new Error(
            `context band field "${name}": rendered ${JSON.stringify(seg)}, which does not name ${JSON.stringify(value)} — ` +
              `a reported disagreement must carry BOTH values or it cannot be acted on`,
          )
        }
      }
    }
    // The AGREEING fields must NOT wear the mark: a ⚠ that fires on healthy
    // state is a warning nobody reads.
    for (const name of ['host', 'project', 'repo']) {
      expect(rendered[name] ?? '').not.toContain(MISMATCH_MARK)
    }
  } finally {
    await act(async () => tree.unmount())
  }
})

test('CRIT 2 — the four absence markers are DISTINCT, and no field ever renders blank', () => {
  // Each row drives one arm to its marker. Purely resolved (no screen) because
  // this is about the vocabulary, and a mounted probe per arm buys nothing.
  const cases: { label: string; field: string; want: string; identity: ReturnType<typeof resolveContextIdentity> }[] = [
    {
      label: 'no enrolled host holds the lease — the server runs it',
      field: 'host',
      want: ABSENT_SERVER_LOCAL,
      identity: resolveContextIdentity({}, conn, { host: null, execution_target: 'managed' }),
    },
    {
      label: 'the server projected no context at all (an older server)',
      field: 'host',
      want: ABSENT_UNKNOWN,
      identity: resolveContextIdentity({}, conn, undefined),
    },
    {
      label: 'a server-local cwd measured outside a work tree',
      field: 'repo',
      want: ABSENT_NO_REPO,
      identity: resolveContextIdentity({}, conn, {
        cwd: '/srv/scratch',
        execution_target: 'managed',
        repo_status: 'not_a_repo',
      }),
    },
    {
      label: 'nothing configured and nothing dialled',
      field: 'project',
      want: ABSENT_UNSET,
      identity: resolveContextIdentity({}, { projectUrl: '', token: '', dataset: '' }, undefined),
    },
  ]

  const seen = new Set<string>()
  for (const c of cases) {
    const f = contextField(c.identity, c.field)
    if (f === undefined) throw new Error(`no "${c.field}" field at all — ${c.label}`)
    const shown = fieldDisplay(f)
    if (!shown.startsWith(c.want)) {
      throw new Error(
        `context field "${c.field}" (${c.label}): displayed ${JSON.stringify(shown)}, expected it to lead with ` +
          `${JSON.stringify(c.want)} — a typed absence that reads as another absence is a lie about which one it is`,
      )
    }
    seen.add(c.want)
  }
  // FOUR distinct strings, not four names for one: collapsing any pair is
  // exactly the failure law 2 forbids.
  expect(seen.size).toBe(4)

  // And nothing, in any arm, ever renders as the empty string.
  for (const c of cases) {
    for (const f of c.identity.fields) {
      if (fieldDisplay(f).trim() === '') {
        throw new Error(
          `context field "${f.name}" (${c.label}) rendered BLANK — a blank where a value belongs is the ` +
            `failure this band exists to prevent`,
        )
      }
    }
  }
})

test('CRIT 2 — an unset dataset never reaches the eye wearing the substituted default', () => {
  // connectionFromConfig substitutes 'production' for an empty dataset. Showing
  // that alone would print the most-likely-wrong value as a deliberate choice.
  const id = resolveContextIdentity({ dataset: '' }, { ...conn, dataset: 'production' }, undefined)
  const f = contextField(id, 'dataset')!
  expect(fieldDisplay(f)).toBe(`${ABSENT_UNSET} — the connection uses "production"`)
  expect(f.mismatch).toBe(true)
})

/* ── 3 — the SSE resume path re-reads the facts, in place ──────────────────── */

test('CRIT 3 — after the SSE resume re-attaches, the band re-reads the session facts and updates in place', async () => {
  const moved: ChatSessionContext = { ...wire, host: 'mac-studio-02' }
  // The seed read, then the resume re-read. A resolved-value queue rather than
  // a single mockResolvedValue: the point is that a SECOND read happens.
  mockGet
    .mockResolvedValueOnce({ id: 's1', messages: [], context: wire })
    .mockResolvedValue({ id: 's1', messages: [], context: moved })

  const tree = await mount({ claim })
  try {
    expect(band(tree)['host']).toBe('host mac-mini-01')
    const readsAfterSeed = mockGet.mock.calls.length

    // The FIRST 'open' is this start's initial attach — the seed GET that just
    // ran IS that read, so nothing may re-fire.
    await act(async () => live().onStatus?.('open'))
    expect(mockGet.mock.calls.length).toBe(readsAfterSeed)
    expect(band(tree)['host']).toBe('host mac-mini-01')

    // A drop the client survives by cursor…
    await act(async () => live().onStatus?.('degraded'))
    // …and the resume landing. THIS is the re-read.
    await act(async () => live().onStatus?.('open'))

    expect(mockGet.mock.calls.length).toBe(readsAfterSeed + 1)
    // IN PLACE: same mounted tree, no remount, no second stream opened.
    expect(streams.length).toBe(1)
    expect(band(tree)['host']).toBe('host mac-studio-02')
  } finally {
    await act(async () => tree.unmount())
  }
})

test('CRIT 3 — a resume re-read that FAILS keeps the facts the band already holds', async () => {
  mockGet
    .mockResolvedValueOnce({ id: 's1', messages: [], context: wire })
    .mockRejectedValue(new Error('offline'))
  const tree = await mount({ claim })
  try {
    await act(async () => live().onStatus?.('open'))
    await act(async () => live().onStatus?.('degraded'))
    await act(async () => live().onStatus?.('open'))
    // The last thing the server actually stated still stands — a failed refresh
    // is not evidence the session moved, and blanking the band on it would be
    // the loudest possible way to say nothing.
    expect(band(tree)['host']).toBe('host mac-mini-01')
  } finally {
    await act(async () => tree.unmount())
  }
})

/* ── the plumbing guard (the mutation target) ──────────────────────────────── */

test('GUARD — every one of the six fields is plumbed end to end, and each is named in its own failure', async () => {
  // A fixture where all six carry a DISTINCT, recognisable value and NOTHING
  // disagrees: a field wired to the wrong source cannot coincidentally match
  // another's, and every segment is a clean value, so severing one plumbing
  // line reds THAT field's message and only that one.
  const agreeing: InstanceConnection = {
    projectUrl: 'https://conn.fixture',
    token: 'tkn',
    dataset: 'ds-fixture',
    workspace: 'ws-fixture',
    project: 'proj-fixture',
  }
  mockGet.mockResolvedValue({
    id: 's1',
    messages: [],
    context: {
      host: 'host-fixture',
      execution_target: 'managed',
      cwd: '/repo/fixture',
      workspace: 'ws-fixture',
      repo_root: '/repo/fixture',
      repo_status: 'set',
    },
  })
  const tree = await mount({
    connection: agreeing,
    claim: {
      server: 'https://conn.fixture',
      workspace: 'ws-fixture',
      project: 'proj-fixture',
      dataset: 'ds-fixture',
    },
  })
  try {
    expectBand(band(tree), {
      host: 'host host-fixture',
      server: 'server https://conn.fixture',
      workspace: 'workspace ws-fixture',
      project: 'project proj-fixture',
      dataset: 'dataset ds-fixture',
      repo: 'repo /repo/fixture',
    })
  } finally {
    await act(async () => tree.unmount())
  }
})

test('GUARD — the segment text the band paints IS contextSegmentText, not a look-alike', () => {
  // A test that re-assembles its own expected label cannot catch a band that
  // stopped rendering the field NAME. Pin the shared builder instead.
  expect(contextSegmentText('dataset', 'staging', false)).toBe('dataset staging')
  expect(contextSegmentText('dataset', 'staging', true)).toBe(`${MISMATCH_MARK} dataset staging`)
})
