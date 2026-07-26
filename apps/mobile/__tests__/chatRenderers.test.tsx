// The six typed chat-* renderers, the role taxonomy, and the two tripwires
// that keep this surface from drifting off the other three (t3w2-s3).
//
// FOUR law families are pinned here, each chosen because a plausible future
// edit breaks it SILENTLY:
//
//   1. REGISTRY ≡ AUTHORED CASES (charter D31) — every registered block type
//      has an authored case that renders without hitting the unknown-block
//      fallback, and the registry is exactly 43 entries. Adding a renderer
//      without a case, or deleting one, reds here. Mirrors the react twin's
//      `covers EXACTLY the registered types` (PortableDoc.test.tsx).
//   2. THE GOLDEN FLOOR (charter D31) — the GENERATOR-OWNED fixture
//      (`mix barkpark.chat.gen_golden_toolrows` is its sole writer) is
//      IMPORTED, never copied. Mobile is its third consumer, after
//      internal/pdrender and the Elixir freshness test. Every variant renders
//      its projection words; all six promoted types are covered.
//   3. THE PORTED SEMANTICS — the lowercase thinking label (D30), the shared
//      20-line fold budget, the server's diff lines being TRUSTED rather than
//      re-derived, the todo glyph/progress vocabulary, and the card defaults.
//   4. THE ROLE TAXONOMY — which of the eight persisted roles render blocks,
//      which keep a provenance line, and the forward-compatible default arm
//      (internal/chat/render.go renderMessage's twin).
//
// Like the sibling suites this walks the element trees the PURE renderers
// return — no native host, no emulator.
import type { ReactElement, ReactNode } from 'react'

// The generator-owned cross-surface fixture, consumed straight from the Go
// testdata mirror. An ESM default import (NOT fs/path — @types/node is absent,
// so the fs form does not typecheck) and strictly test-side, so metro never
// bundles it into the app.
import goldenToolrows from '../../../internal/pdrender/testdata/chat_golden_toolrows.json'

import {
  CardRow,
  TranscriptRow,
  bodyRender,
  chatBlockCtx,
  rendersBlocks,
  roleKind,
  type Row,
} from '../src/screens/ChatSessionScreen'
import type { ChatMessage } from '../src/chat/wire'
import { MermaidIsland } from '../src/papers/portabledoc/MermaidIsland'
import {
  BLOCK_RENDERERS,
  renderBlockNative,
  resetUnknownBlockLog,
  type BlockCtx,
} from '../src/papers/portabledoc/blocks'
import {
  CHAT_BLOCK_TYPES,
  CHAT_DIFF_BUDGET,
  CHAT_RENDERERS,
  chatDiffPath,
  chatStatusLabel,
  chatThinkingLabel,
  todoProgress,
  todoStatus,
} from '../src/papers/portabledoc/chat'
import { inlineCodeStyle, renderInlineNodes } from '../src/papers/portabledoc/inlines'
import { light, type Theme } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme: Theme = light
const chat: BlockCtx = { theme, register: 'chat' }
const paper: BlockCtx = { theme }

/* ── element walking ────────────────────────────────────────────────────────── */

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

interface Walk {
  text: string
  styles: Record<string, unknown>[]
  islands: number
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (isElement(node)) {
    const props = node.props as Record<string, unknown>
    if (node.type === MermaidIsland) {
      acc.islands++
      return // stateful leaf
    }
    const raw = props.style
    if (raw !== undefined) {
      const parts = Array.isArray(raw) ? raw : [raw]
      acc.styles.push(Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>)
    }
    walkNode(props.children as ReactNode, acc)
  }
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', styles: [], islands: 0 }
  walkNode(node, acc)
  return acc
}

function text(block: unknown, ctx: BlockCtx = chat): string {
  return walk(renderBlockNative(block, ctx, 0)).text
}

/* ── 1. the registry tripwire (charter D31) ─────────────────────────────────── */

// One authored case per registered type. This list is the tripwire's other
// half: it must stay ≡ the registry, so a renderer added without a case (or a
// case left behind by a deleted renderer) reds.
const CASES: { type: string; block: Record<string, unknown> }[] = [
  { type: 'heading', block: { type: 'heading', level: 2, text: 'Heading' } },
  { type: 'paragraph', block: { type: 'paragraph', text: 'body copy' } },
  { type: 'eyebrow', block: { type: 'eyebrow', text: 'EYEBROW' } },
  { type: 'byline', block: { type: 'byline', items: ['Ada', 'Grace'] } },
  { type: 'ingress', block: { type: 'ingress', text: 'the lede' } },
  { type: 'pullquote', block: { type: 'pullquote', text: 'pulled' } },
  { type: 'list', block: { type: 'list', items: ['one', 'two'] } },
  { type: 'bulletList', block: { type: 'bulletList', items: ['one'] } },
  { type: 'bullet_list', block: { type: 'bullet_list', items: ['one'] } },
  { type: 'bulleted-list', block: { type: 'bulleted-list', items: ['one'] } },
  { type: 'bulleted_list', block: { type: 'bulleted_list', items: ['one'] } },
  { type: 'numbered_list', block: { type: 'numbered_list', items: ['one'] } },
  { type: 'callout', block: { type: 'callout', tone: 'info', title: 'Note', text: 'careful' } },
  { type: 'code', block: { type: 'code', value: 'const x = 1' } },
  { type: 'divider', block: { type: 'divider' } },
  { type: 'image', block: { type: 'image', src: 'https://example.com/a.png', alt: 'a' } },
  {
    type: 'figure',
    block: { type: 'figure', child: { type: 'paragraph', text: 'inner' }, caption: 'Figure 1. cap' },
  },
  { type: 'diagram', block: { type: 'diagram', source: 'flowchart TD\n A --> B' } },
  { type: 'table', block: { type: 'table', head: ['h'], rows: [['cell']] } },
  { type: 'toc', block: { type: 'toc', items: [{ text: 'Outline', level: 1 }] } },
  { type: 'stat', block: { type: 'stat', value: '42', label: 'answers' } },
  { type: 'stats', block: { type: 'stats', items: [{ value: '7', label: 'seven' }] } },
  { type: 'stat-grid', block: { type: 'stat-grid', items: [{ value: '7' }] } },
  { type: 'note', block: { type: 'note', label: 'NB', text: 'noted' } },
  { type: 'notes', block: { type: 'notes', items: [{ text: 'noted' }] } },
  { type: 'cards', block: { type: 'cards', items: [{ title: 'Card', text: 'body' }] } },
  { type: 'steps', block: { type: 'steps', steps: [{ title: 'First' }] } },
  { type: 'expandable', block: { type: 'expandable', summary: 'More', blocks: [] } },
  { type: 'blockquote', block: { type: 'blockquote', text: 'quoted', cite: 'someone' } },
  { type: 'quote', block: { type: 'quote', text: 'quoted' } },
  { type: 'footnote', block: { type: 'footnote', notes: [{ text: 'a note' }] } },
  { type: 'section', block: { type: 'section', title: 'Sec', blocks: [] } },
  {
    type: 'columns',
    block: { type: 'columns', columns: [[{ type: 'paragraph', text: 'col' }]] },
  },
  { type: 'terminal', block: { type: 'terminal', title: 'sh', children: [] } },
  { type: 'tasks', block: { type: 'tasks', snapshot: [{ title: 'T', status: 'open' }] } },
  { type: 'task-list', block: { type: 'task-list', snapshot: [{ title: 'T', status: 'done' }] } },
  { type: 'action', block: { type: 'action', label: 'Open' } },
  // the six typed chat rows
  {
    type: 'chat-tool-diff',
    block: {
      type: 'chat-tool-diff',
      input: { file_path: 'a.ex' },
      lines: [{ op: '+', text: 'added' }],
      added: 1,
      removed: 0,
    },
  },
  {
    type: 'chat-todo',
    block: { type: 'chat-todo', todos: [{ content: 'do it', status: 'pending' }] },
  },
  { type: 'chat-thinking', block: { type: 'chat-thinking', tokens: 12 } },
  {
    type: 'chat-approval',
    block: { type: 'chat-approval', tool_name: 'Bash', summary: 's', approval_status: 'pending' },
  },
  {
    type: 'chat-question',
    block: { type: 'chat-question', questions: [{ question: 'Q?', options: ['A'] }] },
  },
  { type: 'chat-plan', block: { type: 'chat-plan', title: 'Plan', preview: 'p' } },
]

describe('registry tripwire (charter D31)', () => {
  it('covers EXACTLY the registered types (registry ≡ authored cases)', () => {
    const authored = CASES.map((c) => c.type).sort()
    const registered = Object.keys(BLOCK_RENDERERS).sort()
    expect(authored).toEqual(registered)
    // 37 paper-surface entries (30 canonical + 7 function-identity aliases)
    // plus the six typed chat-* rows this slice registers.
    expect(registered).toHaveLength(43)
  })

  it('enumerates the 7 function-identity aliases — numbered_list is NOT one', () => {
    const aliasOf: [string, string][] = [
      ['bulletList', 'list'],
      ['bullet_list', 'list'],
      ['bulleted-list', 'list'],
      ['bulleted_list', 'list'],
      ['quote', 'blockquote'],
      ['stat-grid', 'stats'],
      ['task-list', 'tasks'],
    ]
    for (const [alias, canonical] of aliasOf) {
      expect(BLOCK_RENDERERS[alias]).toBe(BLOCK_RENDERERS[canonical])
    }
    // The alias set is exactly 7: every OTHER key is its own function.
    const aliases = Object.keys(BLOCK_RENDERERS).filter((k) =>
      Object.keys(BLOCK_RENDERERS).some((j) => j !== k && BLOCK_RENDERERS[j] === BLOCK_RENDERERS[k]),
    )
    expect(aliases.sort()).toEqual(
      ['bulletList', 'bullet_list', 'bulleted-list', 'bulleted_list', 'list', 'blockquote', 'quote', 'stat-grid', 'stats', 'task-list', 'tasks'].sort(),
    )
    // numbered_list is a DISTINCT ordered:true wrapper, never an alias of list.
    expect(BLOCK_RENDERERS.numbered_list).not.toBe(BLOCK_RENDERERS.list)
    expect(text({ type: 'numbered_list', items: ['a'] })).toContain('1.')
    expect(text({ type: 'list', items: ['a'] })).toContain('•')
  })

  it('every authored case renders WITHOUT the unknown-block fallback', () => {
    resetUnknownBlockLog()
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      for (const { type, block } of CASES) {
        const out = walk(renderBlockNative(block, chat, 0))
        expect(`${type}: ${out.text}`).not.toContain('Unsupported block')
      }
      expect(warn).not.toHaveBeenCalled()
    } finally {
      warn.mockRestore()
    }
  })

  it('the six chat renderers are registered by SPREAD — same function identities', () => {
    // Copy before sorting: CHAT_BLOCK_TYPES is frozen (an in-place .sort()
    // here used to silently reorder what every later reader saw).
    expect([...CHAT_BLOCK_TYPES].sort()).toEqual(
      ['chat-approval', 'chat-plan', 'chat-question', 'chat-thinking', 'chat-todo', 'chat-tool-diff'].sort(),
    )
    expect(Object.isFrozen(CHAT_BLOCK_TYPES)).toBe(true)
    for (const t of CHAT_BLOCK_TYPES) expect(BLOCK_RENDERERS[t]).toBe(CHAT_RENDERERS[t])
  })

  it('an UNregistered chat-x still degrades through the shared unknown path', () => {
    resetUnknownBlockLog()
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      expect(text({ type: 'chat-teleport' })).toContain('Unsupported block: chat-teleport')
      expect(warn).toHaveBeenCalledTimes(1)
    } finally {
      warn.mockRestore()
    }
  })
})

/* ── 2. chat-thinking: the lowercase golden form (charter D30) ──────────────── */

describe('chat-thinking (charter D30 — the Elixir/react form is golden)', () => {
  it('renders the LOWERCASE "thought for ~N tokens", never the Go capitalization', () => {
    const out = text({ type: 'chat-thinking', tokens: 1280 })
    expect(out).toBe('✻ thought for ~1280 tokens')
    // The Go TUI's "✻ Thought for N tokens" is the OUTLIER — asserting its
    // absence is what makes a capitalization regression red.
    expect(out).not.toContain('Thought for')
    expect(out).not.toContain('Thinking')
  })

  it('degrades to a bare "thought" without an integer count — never a fake number', () => {
    for (const tokens of [undefined, null, 'lots', 12.5, {}]) {
      expect(chatThinkingLabel(tokens)).toBe('thought')
      expect(text({ type: 'chat-thinking', tokens })).toBe('✻ thought')
    }
    // Zero IS an integer, so it keeps the counted form (Elixir is_integer/1).
    expect(chatThinkingLabel(0)).toBe('thought for ~0 tokens')
  })
})

/* ── 3. chat-tool-diff: the server's lines, the shared budget ────────────────── */

describe('chat-tool-diff', () => {
  it('TRUSTS the server lines — it never re-derives a diff from input', () => {
    // `input` says a→b; the SERVER's lines say something else entirely. A ported
    // DP-LCS would paint the input's derivation and lose the row Studio shows.
    const out = text({
      type: 'chat-tool-diff',
      input: { file_path: 'x.ex', old_string: 'alpha', new_string: 'omega' },
      lines: [
        { op: '=', text: 'context' },
        { op: '-', text: 'SERVERSIDE_REMOVED' },
        { op: '+', text: 'SERVERSIDE_ADDED' },
      ],
      added: 1,
      removed: 1,
    })
    expect(out).toContain('SERVERSIDE_REMOVED')
    expect(out).toContain('SERVERSIDE_ADDED')
    expect(out).not.toContain('alpha')
    expect(out).not.toContain('omega')
  })

  it('folds at the SHARED 20-line budget with an honest overflow footnote', () => {
    expect(CHAT_DIFF_BUDGET).toBe(20)
    const lines = Array.from({ length: 25 }, (_, i) => ({ op: '+', text: `L${i}` }))
    const out = text({ type: 'chat-tool-diff', lines, added: 25, removed: 0 })
    for (let i = 0; i < CHAT_DIFF_BUDGET; i++) expect(out).toContain(`L${i}`)
    for (let i = CHAT_DIFF_BUDGET; i < 25; i++) expect(out).not.toContain(`L${i}`)
    expect(out).toContain('… +5 more lines')
  })

  it('a diff AT the budget does not claim an overflow', () => {
    const lines = Array.from({ length: CHAT_DIFF_BUDGET }, (_, i) => ({ op: '+', text: `L${i}` }))
    expect(text({ type: 'chat-tool-diff', lines })).not.toContain('more lines')
  })

  it('a `gap` hunk separator never spends budget (it is a rule, not a line)', () => {
    const lines = [
      ...Array.from({ length: 10 }, (_, i) => ({ op: '+', text: `A${i}` })),
      { op: 'gap', text: '' },
      ...Array.from({ length: 10 }, (_, i) => ({ op: '+', text: `B${i}` })),
    ]
    const out = text({ type: 'chat-tool-diff', lines })
    expect(out).toContain('A9')
    expect(out).toContain('B9') // the 20th DRAWABLE line, past 20 raw entries
    expect(out).not.toContain('more lines')
  })

  // The separator rule is the 1px border-colored <View> the gap arm emits —
  // countable through the walker's style capture.
  const gapRules = (w: Walk): number =>
    w.styles.filter((s) => s.height === 1 && s.backgroundColor === theme.border).length

  it('a gap of a fully folded hunk never DRAWS once the budget is spent (D40)', () => {
    const lines = [
      ...Array.from({ length: CHAT_DIFF_BUDGET }, (_, i) => ({ op: '+', text: `C${i}` })),
      { op: 'gap', text: '' },
      ...Array.from({ length: 4 }, (_, i) => ({ op: '+', text: `D${i}` })),
    ]
    const w = walk(renderBlockNative({ type: 'chat-tool-diff', lines }, chat, 0))
    // The rule would introduce rows the fold already discarded — chrome for
    // nothing. It stays in the folded tail with its hunk.
    expect(gapRules(w)).toBe(0)
    // …and the footnote counts the 4 folded DRAWABLE rows only, never the gap.
    expect(w.text).toContain('… +4 more lines')
    expect(w.text).not.toContain('+5 more lines')
  })

  it('a gap BETWEEN drawn hunks still draws its rule (the D40 fix removes none)', () => {
    const lines = [
      { op: '+', text: 'top' },
      { op: 'gap', text: '' },
      { op: '+', text: 'bottom' },
    ]
    const w = walk(renderBlockNative({ type: 'chat-tool-diff', lines }, chat, 0))
    expect(gapRules(w)).toBe(1)
  })

  it('reads the path from the LIVE nested input.file_path, not just a flat path', () => {
    expect(chatDiffPath({ type: 'chat-tool-diff', path: 'flat.ex' })).toBe('flat.ex')
    expect(
      chatDiffPath({ type: 'chat-tool-diff', input: { file_path: 'lib/barkpark/chat.ex' } }),
    ).toBe('lib/barkpark/chat.ex')
    expect(chatDiffPath({ type: 'chat-tool-diff' })).toBe('')
    // The consequence: the header actually draws it.
    expect(
      text({
        type: 'chat-tool-diff',
        input: { file_path: 'lib/barkpark/chat.ex' },
        lines: [{ op: '+', text: 'x' }],
      }),
    ).toContain('lib/barkpark/chat.ex')
  })

  it('falls back to counting ops when the server omits the tally', () => {
    const out = text({
      type: 'chat-tool-diff',
      lines: [
        { op: '+', text: 'a' },
        { op: '+', text: 'b' },
        { op: '-', text: 'c' },
      ],
    })
    expect(out).toContain('+2')
    expect(out).toContain('−1')
    // A DECLARED zero is honest data, not an absent key.
    expect(text({ type: 'chat-tool-diff', lines: [{ op: '=', text: 'x' }], added: 0, removed: 0 }))
      .toContain('+0')
  })

  it('paints add/remove/context in the ok / danger / muted roles, never a new palette', () => {
    const w = walk(
      renderBlockNative(
        {
          type: 'chat-tool-diff',
          lines: [
            { op: '+', text: 'plus' },
            { op: '-', text: 'minus' },
            { op: '=', text: 'same' },
          ],
        },
        chat,
        0,
      ),
    )
    const colors = w.styles.map((s) => s.color)
    expect(colors).toContain(theme.success)
    expect(colors).toContain(theme.danger)
    expect(colors).toContain(theme.textMuted)
  })
})

/* ── 4. chat-todo ───────────────────────────────────────────────────────────── */

describe('chat-todo', () => {
  const todos = [
    { content: 'Wire the transport', status: 'completed' },
    { content: 'Render the toolrows', status: 'in_progress', active_form: 'Rendering the toolrows' },
    { content: 'Prove the parity gate', status: 'pending' },
  ]

  it('renders the checklist with the ☒/◐/☐ vocabulary and an HONEST N/M tally', () => {
    const out = text({ type: 'chat-todo', todos })
    expect(out).toContain('● Update todos')
    // In-progress is NOT done — only completed counts.
    expect(out).toContain('· 1/3 done')
    expect(todoProgress(todos)).toBe('1/3 done')
    expect(out).toContain('☒')
    expect(out).toContain('◐')
    expect(out).toContain('☐')
    expect(out).toContain('→ Rendering the toolrows')
  })

  it('accepts BOTH the camelCase and snake_case activeForm spellings', () => {
    for (const key of ['activeForm', 'active_form']) {
      const out = text({
        type: 'chat-todo',
        todos: [{ content: 'c', status: 'in_progress', [key]: 'Doing it' }],
      })
      expect(out).toContain('→ Doing it')
    }
  })

  it('shows the activeForm only while in_progress', () => {
    expect(
      text({ type: 'chat-todo', todos: [{ content: 'c', status: 'completed', active_form: 'Doing it' }] }),
    ).not.toContain('Doing it')
  })

  it('an empty list is an HONEST empty bar, never a blank box', () => {
    const out = text({ type: 'chat-todo', todos: [] })
    expect(out).toContain('● Update todos')
    expect(out).toContain('⎿ no items')
    expect(out).not.toContain('done')
  })

  it('folds an unrecognized status to pending (normalize_status/1)', () => {
    expect(todoStatus('in_progress')).toBe('in_progress')
    expect(todoStatus('completed')).toBe('completed')
    for (const junk of ['blocked', '', undefined, 7]) expect(todoStatus(junk)).toBe('pending')
    expect(text({ type: 'chat-todo', todos: [{ content: 'c', status: 'blocked' }] })).toContain('☐')
  })
})

/* ── 5. the interactive cards (D35 — visual only, never an answer control) ───── */

describe('chat-approval / chat-question / chat-plan', () => {
  it('labels every status word, passing an unknown one through verbatim', () => {
    expect(chatStatusLabel('pending')).toBe('pending')
    expect(chatStatusLabel('allowed')).toBe('✓ allowed')
    expect(chatStatusLabel('denied')).toBe('⊘ denied')
    expect(chatStatusLabel('canceled')).toBe('— canceled')
    expect(chatStatusLabel('quantum')).toBe('quantum')
  })

  it('approval: pending asks "Allow X?"; a decided one just names the tool', () => {
    expect(text({ type: 'chat-approval', tool_name: 'Bash', approval_status: 'pending' })).toContain(
      'Allow Bash?',
    )
    const decided = text({ type: 'chat-approval', tool_name: 'Bash', approval_status: 'allowed' })
    expect(decided).toContain('Bash')
    expect(decided).not.toContain('Allow Bash?')
    expect(decided).toContain('✓ allowed')
  })

  it('approval: an ABSENT key takes the default; a present-but-empty one does not', () => {
    // Map.get/3 semantics — the react twin's `== null` test.
    expect(text({ type: 'chat-approval' })).toContain('Allow tool?')
    expect(text({ type: 'chat-approval', tool_name: '' })).toContain('Allow ?')
  })

  it('question: prompts + option chips; an empty set stays honest', () => {
    const out = text({
      type: 'chat-question',
      questions: [{ question: 'Which database?', options: ['Postgres', 'SQLite'] }],
    })
    expect(out).toContain('Question')
    expect(out).toContain('Which database?')
    expect(out).toContain('Postgres')
    expect(out).toContain('SQLite')
    expect(text({ type: 'chat-question', questions: [] })).toContain('⎿ no question')
  })

  it('question: a non-string option is skipped, never painted as [object Object]', () => {
    const out = text({
      type: 'chat-question',
      questions: [{ question: 'Q?', options: [{ label: 'Nope' }, 'Yep'] }],
    })
    expect(out).toContain('Yep')
    expect(out).not.toContain('object')
  })

  it('plan: title + preview, defaulting the title honestly', () => {
    expect(text({ type: 'chat-plan', title: 'Ship it', preview: 'lede' })).toContain('Ship it')
    expect(text({ type: 'chat-plan' })).toContain('Proposed plan')
  })

  it('a card BLOCK never renders an answer control (D35 — the envelope owns it)', () => {
    for (const block of [
      { type: 'chat-approval', tool_name: 'Bash', approval_status: 'pending' },
      { type: 'chat-question', questions: [{ question: 'Q?' }], approval_status: 'pending' },
      { type: 'chat-plan', title: 'P', approval_status: 'pending' },
    ]) {
      const out = text(block)
      expect(out).not.toContain('Allow</')
      expect(out).not.toMatch(/\bDeny\b/)
    }
  })
})

/* ── 6. the role taxonomy (internal/chat/render.go renderMessage's twin) ─────── */

function messageRow(m: Partial<ChatMessage> & { role: string }): Row {
  return { key: 'm-1', kind: 'message', message: { seq: 1, ...m } }
}

const toolBlock = [{ type: 'chat-tool-diff', lines: [{ op: '+', text: 'NEWLINE_HERE' }], added: 1 }]

describe('role taxonomy', () => {
  it('classifies the eight persisted roles; system AND unknown fold to structural', () => {
    expect(roleKind('assistant')).toBe('assistant')
    expect(roleKind('user')).toBe('user')
    for (const r of ['approval', 'question', 'plan']) expect(roleKind(r)).toBe('card')
    for (const r of ['tool', 'todo', 'thinking']) expect(roleKind(r)).toBe('block')
    // The forward-compatible default arm IS structural: a `system` row and an
    // unknown future role paint the identical dim provenance line, so a
    // separate `unknown` kind had no observable consequence and was folded in.
    expect(roleKind('system')).toBe('structural')
    expect(roleKind('teleport')).toBe('structural')
  })

  it('exactly SIX block-bearing roles — user and system are deliberately out', () => {
    const bearing = ['assistant', 'user', 'approval', 'question', 'plan', 'tool', 'todo', 'thinking', 'system']
      .filter(rendersBlocks)
      .sort()
    expect(bearing).toEqual(
      ['approval', 'assistant', 'plan', 'question', 'thinking', 'todo', 'tool'].sort(),
    )
    expect(rendersBlocks('user')).toBe(false)
    expect(rendersBlocks('system')).toBe(false)
  })

  it('bodyRender routes tool/todo/thinking rows to their blocks (S3 flips S2)', () => {
    for (const role of ['tool', 'todo', 'thinking']) {
      expect(bodyRender(messageRow({ role, blocks: toolBlock, source_markdown: 'Read(app.js)' }))).toEqual({
        kind: 'blocks',
        blocks: toolBlock,
      })
    }
  })

  it('TranscriptRow RENDERS a tool row as its typed block, not one dim line', () => {
    const w = walk(
      TranscriptRow({
        row: messageRow({ role: 'tool', blocks: toolBlock, source_markdown: 'Edit(chat.ex)' }),
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toContain('NEWLINE_HERE')
    // …and NOT the provenance line it replaced.
    expect(w.text).not.toContain('tool: Edit(chat.ex)')
  })

  it('a BLOCKLESS tool row degrades honestly to the provenance line', () => {
    const w = walk(
      TranscriptRow({
        row: messageRow({ role: 'tool', source_markdown: 'Read(app.js)' }),
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toBe('tool: Read(app.js)')
  })

  it('a user row NEVER renders blocks, even when the server sends them (#6126)', () => {
    expect(
      bodyRender(messageRow({ role: 'user', blocks: toolBlock, source_markdown: 'what I typed' })),
    ).toEqual({ kind: 'text', text: 'what I typed' })
  })

  it('an unknown role renders its source, never a crash or a blank', () => {
    const w = walk(
      TranscriptRow({
        row: messageRow({ role: 'teleport', source_markdown: 'from the future' }),
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toContain('from the future')
  })
})

describe('CardRow: typed block body, envelope-driven answer (D35)', () => {
  const approvalMsg: ChatMessage = {
    seq: 3,
    role: 'approval',
    source_markdown: 'RAW MARKDOWN ASK',
    blocks: [
      { type: 'chat-approval', tool_name: 'Bash', summary: 'command: rm -rf build', approval_status: 'pending' },
    ],
    metadata: { request_id: 'req-1', approval_status: 'pending' },
  }

  it('renders the chat-approval BLOCK as the body — not the raw markdown', () => {
    const w = walk(
      CardRow({
        m: approvalMsg,
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toContain('Allow Bash?')
    expect(w.text).toContain('command: rm -rf build')
    expect(w.text).not.toContain('RAW MARKDOWN ASK')
  })

  it('KEEPS the envelope-driven Allow/Deny footer alongside the block body', () => {
    const w = walk(
      CardRow({
        m: approvalMsg,
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toContain('Allow Bash?') // the block
    expect(w.text).toContain('Deny') // the envelope's control
  })

  it('a blockless card keeps the plain markdown it always showed', () => {
    const w = walk(
      CardRow({
        m: { seq: 4, role: 'plan', source_markdown: 'plain plan text' },
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toContain('plain plan text')
  })
})

/* ── 7. the GENERATOR-OWNED golden floor (charter D31) ───────────────────────── */

// The fixture's sole writer is `mix barkpark.chat.gen_golden_toolrows`, which
// mirrors it byte-for-byte into api/test/support/fixtures and this Go testdata
// dir. Mobile is the THIRD CONSUMER: it imports, never copies. `git diff`
// showing a new fixture file under apps/mobile would BE the violation.

const WORD_RE = /[A-Za-z0-9]{4,}/g

/** The >=4-char alphanumeric tokens whose presence proves the block realized —
 * the exact `significantWords` rule the Go leg uses. */
function significantWords(s: string): string[] {
  return s.match(WORD_RE) ?? []
}

/** The haystack: all whitespace removed, lowercased — the Go `collapse` twin,
 * so render-time wrapping and padding cannot fake a miss. */
function collapse(s: string): string {
  return s.replace(/\s+/g, '').toLowerCase()
}

describe('golden toolrows floor (the generator-owned fixture, imported)', () => {
  it('reads the generator fixture — scope + provenance + variant floor', () => {
    expect(goldenToolrows.scope).toBe('chat-tool-todo-thinking-rows')
    expect(goldenToolrows._comment).toContain('gen_golden_toolrows')
    expect(goldenToolrows.variants.length).toBeGreaterThanOrEqual(6)
  })

  const variants = goldenToolrows.variants as {
    name: string
    kind: string
    block: Record<string, unknown> & { type: string }
    projection: { type: string; text: string; overflow?: number }
  }[]

  it.each(variants.map((v) => [v.name, v] as const))(
    'variant %s renders every projection word through BLOCK_RENDERERS',
    (_name, v) => {
      // The block's own type must have a REAL renderer — the whole point of
      // promoting these rows to block types (Law 1).
      expect(v.block.type).toBe(v.projection.type)
      expect(BLOCK_RENDERERS[v.block.type]).toBeDefined()

      const rendered = walk(renderBlockNative(v.block, chat, 0)).text
      expect(rendered).not.toContain('Unsupported block')

      const words = significantWords(v.projection.text)
      expect(words.length).toBeGreaterThan(0)
      const hay = collapse(rendered)
      for (const w of words) expect(hay).toContain(w.toLowerCase())

      // The fold NUMBER (charter D40): a diff variant's footnote shows the
      // generator's drawable-only overflow VERBATIM. Word presence is blind to
      // the number — under a raw-element budget the adjudicating variant
      // (24 drawable + 2 gaps inside the first 20 raw) would render
      // "+6 more lines" and still realize every projected word; the literal
      // "+4" is what reds the non-ratified reading.
      if (v.projection.type === 'chat-tool-diff') {
        const overflow = v.projection.overflow ?? 0
        if (overflow > 0) {
          expect(rendered).toContain(`… +${overflow} more lines`)
        } else {
          expect(rendered).not.toContain('more lines')
        }
      }
    },
  )

  it('carries the adjudicating budget variant (a folding chat-tool-diff)', () => {
    // Without it the fold-number assertion above is vacuously green and a
    // regen could silently shed the D40 lock.
    expect(
      variants.some((v) => v.projection.type === 'chat-tool-diff' && (v.projection.overflow ?? 0) > 0),
    ).toBe(true)
  })

  it('coverage floor: all SIX promoted block types appear in the fixture', () => {
    const seen = new Set(variants.map((v) => v.projection.type))
    for (const want of [
      'chat-tool-diff',
      'chat-todo',
      'chat-thinking',
      'chat-approval',
      'chat-question',
      'chat-plan',
    ]) {
      expect(seen.has(want)).toBe(true)
    }
  })

  it('renders the whole fixture in ONE transcript without a single fallback', () => {
    resetUnknownBlockLog()
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      const out = walk(variants.map((v, i) => renderBlockNative(v.block, chat, i)))
      expect(out.text).not.toContain('Unsupported block')
      expect(warn).not.toHaveBeenCalled()
    } finally {
      warn.mockRestore()
    }
  })
})

/* ── 8. inline code is register-aware (the S2 review addendum) ───────────────── */

describe('inline code agrees with the fenced code surface per register', () => {
  it('a chat inline span paints on codeBg/codeFg — the SAME surface as a fence', () => {
    const s = inlineCodeStyle(chat)
    expect(s.backgroundColor).toBe(theme.codeBg)
    expect(s.color).toBe(theme.codeFg)
    // The bug this kills: #ffffff on the #f6f7f6 light transcript is invisible.
    expect(s.backgroundColor).not.toBe(theme.surface)
  })

  it('the PAPER register is byte-unchanged: surface + text, register omitted or not', () => {
    expect(inlineCodeStyle(paper)).toEqual(inlineCodeStyle({ theme, register: 'paper' }))
    expect(inlineCodeStyle(paper)).toEqual({
      fontFamily: 'monospace',
      fontSize: 13,
      backgroundColor: theme.surface,
      color: theme.text,
    })
  })

  it('reaches a real inline `code` mark AND a `code` node through the walker', () => {
    for (const nodes of [
      [{ type: 'text', value: 'pnpm test', marks: ['code'] }],
      [{ type: 'code', value: 'pnpm test' }],
    ]) {
      const inChat = walk(renderInlineNodes(nodes, chat)).styles
      const inPaper = walk(renderInlineNodes(nodes, paper)).styles
      expect(inChat.some((s) => s.backgroundColor === theme.codeBg)).toBe(true)
      expect(inPaper.some((s) => s.backgroundColor === theme.surface)).toBe(true)
    }
  })

  it('reaches a chat PARAGRAPH containing an inline code span (the live path)', () => {
    const w = walk(
      renderBlockNative(
        {
          type: 'paragraph',
          content: [
            { type: 'text', value: 'run ' },
            { type: 'text', value: 'pnpm test', marks: ['code'] },
          ],
        },
        chat,
        0,
      ),
    )
    expect(w.text).toContain('pnpm test')
    expect(w.styles.some((s) => s.backgroundColor === theme.codeBg)).toBe(true)
  })
})
