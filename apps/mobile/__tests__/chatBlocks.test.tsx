// The chat register + the two-phase floor (t3w2-s2-blocks-in-chat).
//
// Three laws are pinned here, all of them things a future edit could break
// silently:
//
//   1. REGISTER DEFAULT — `register` is an optional BlockCtx field and
//      `undefined` IS `'paper'`. The paper reader builds its ctx without the
//      field (PaperReaderScreen.tsx), so this is the non-regression pin for
//      the whole 36-case paperRenderer suite: byte-identical output.
//   2. THE TWO-PHASE FLOOR (charter D8/D9) — the live streaming tail is
//      always plain text; blocks appear only when the turn settles. There is
//      no third state, so a half-written `**bold` cannot flash as markup.
//   3. THE ISLAND'S SECURITY RINGS hold under the chat register exactly as
//      they do under paper — the register never reaches MermaidIsland
//      (charter D22), so its CSP / securityLevel / escaping are unmoved.
//
// Like paperRenderer.test.tsx this walks the element trees the PURE block
// renderers return — no native host.
import type { ReactElement, ReactNode } from 'react'

import { bodyRender, type Row } from '../src/screens/ChatSessionScreen'
import { messageBlocks, type ChatMessage } from '../src/chat/wire'
import { MermaidIsland, islandHtml } from '../src/papers/portabledoc/MermaidIsland'
import { BLOCK_RENDERERS, renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { dark, light, type Theme } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme: Theme = light

/** The ctx the paper reader builds — no `register` field at all. */
const paperDefault: BlockCtx = { theme }
const paperExplicit: BlockCtx = { theme, register: 'paper' }
/** The ctx the transcript builds (ChatSessionScreen blockCtx). */
const chat: BlockCtx = { theme, register: 'chat' }

/* ── element helpers ────────────────────────────────────────────────────────── */

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

/** The flattened style of a rendered block's root element. RN accepts style
 * arrays; the renderers compose `[bodyText(ctx), {…}]`, so flatten in order. */
function rootStyle(node: ReactNode): Record<string, unknown> {
  if (!isElement(node)) throw new Error('expected an element')
  const raw = (node.props as { style?: unknown }).style
  const parts = Array.isArray(raw) ? raw : [raw]
  return Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>
}

interface Walk {
  text: string
  islands: Record<string, unknown>[]
  styles: Record<string, unknown>[]
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
      acc.islands.push(props)
      return // stateful leaf
    }
    if (props.style !== undefined) acc.styles.push(rootStyle(node))
    walkNode(props.children as ReactNode, acc)
  }
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', islands: [], styles: [] }
  walkNode(node, acc)
  return acc
}

function render(block: unknown, ctx: BlockCtx): ReactNode {
  return renderBlockNative(block, ctx, 0)
}

/* ── 1. the register default: undefined IS paper ────────────────────────────── */

describe('register default (charter D22 — an optional field, never a 4th arg)', () => {
  const samples: unknown[] = [
    { type: 'paragraph', text: 'body copy' },
    { type: 'heading', level: 1, text: 'H1' },
    { type: 'heading', level: 2, text: 'H2' },
    { type: 'heading', level: 3, text: 'H3' },
    { type: 'list', items: ['one', 'two'] },
    { type: 'code', value: 'const x = 1' },
    { type: 'callout', tone: 'info', title: 'Note', text: 'careful' },
    { type: 'blockquote', text: 'quoted', cite: 'someone' },
  ]

  it('an omitted register renders byte-identically to an explicit "paper"', () => {
    for (const block of samples) {
      expect(JSON.stringify(render(block, paperDefault))).toBe(
        JSON.stringify(render(block, paperExplicit)),
      )
    }
  })

  it('the paper body stays serif 16/26 with the register omitted', () => {
    expect(rootStyle(render({ type: 'paragraph', text: 'x' }, paperDefault))).toMatchObject({
      fontFamily: 'serif',
      fontSize: 16,
      lineHeight: 26,
      color: theme.text,
    })
  })

  it('paper headings keep their display scale and lead', () => {
    for (const [level, size, marginTop] of [
      [1, 26, 24],
      [2, 22, 20],
      [3, 18, 16],
    ] as const) {
      expect(rootStyle(render({ type: 'heading', level, text: 'h' }, paperDefault))).toMatchObject({
        fontSize: size,
        marginTop,
        lineHeight: size * 1.3,
      })
    }
  })

  it('the paper code frame keeps its surface slab + accent rule', () => {
    const s = rootStyle(render({ type: 'code', value: 'x' }, paperDefault))
    expect(s).toMatchObject({
      backgroundColor: theme.surface,
      borderLeftWidth: 3,
      borderLeftColor: theme.accent,
    })
    expect(s.borderRadius).toBeUndefined()
  })
})

/* ── 2. the chat register ───────────────────────────────────────────────────── */

describe('chat register', () => {
  it('speaks the system sans at the SAME 16/26 measure the assistant turn ships', () => {
    // The #6126 assistant law is 16/26 — rendering a turn as blocks must not
    // change its measure, only its structure. Only the face moves.
    const s = rootStyle(render({ type: 'paragraph', text: 'x' }, chat))
    expect(s.fontSize).toBe(16)
    expect(s.lineHeight).toBe(26)
    expect(s.fontFamily).toBeUndefined()
    expect(s.color).toBe(theme.text)
  })

  it('compresses headings — a turn is not a printed page', () => {
    for (const [level, size, marginTop] of [
      [1, 20, 16],
      [2, 18, 14],
      [3, 16, 12],
    ] as const) {
      const s = rootStyle(render({ type: 'heading', level, text: 'h' }, chat))
      expect(s).toMatchObject({ fontSize: size, marginTop, lineHeight: size * 1.3 })
      // Strictly tighter than the paper register at every level.
      const paper = rootStyle(render({ type: 'heading', level, text: 'h' }, paperDefault))
      expect(size).toBeLessThan(paper.fontSize as number)
      expect(marginTop).toBeLessThan(paper.marginTop as number)
    }
  })

  it('frames fenced code as a code REGION (codeBg/codeFg), not a pulled card', () => {
    const s = rootStyle(render({ type: 'code', value: 'const x = 1' }, chat))
    expect(s).toMatchObject({ backgroundColor: theme.codeBg, borderRadius: 8 })
    expect(s.borderLeftWidth).toBeUndefined()
    expect(walk(render({ type: 'code', value: 'const x = 1' }, chat)).text).toBe('const x = 1')
  })

  it('renders a full assistant turn: bold/italic inlines, lists and a fence', () => {
    const turn = [
      {
        type: 'paragraph',
        content: [
          { type: 'text', value: 'Shipped ' },
          { type: 'text', value: 'bold', marks: ['bold'] },
          { type: 'text', value: ' and ' },
          { type: 'text', value: 'italic', marks: ['italic'] },
        ],
      },
      { type: 'list', items: ['first', 'second'] },
      { type: 'code', value: 'pnpm test', lang: 'bash' },
    ]
    const w = walk(turn.map((b, i) => renderBlockNative(b, chat, i)))
    for (const s of ['Shipped ', 'bold', 'italic', 'first', 'second', 'pnpm test', '•']) {
      expect(w.text).toContain(s)
    }
  })

  it('propagates through container recursion for free (the 6 nesting sites)', () => {
    const nested = {
      type: 'section',
      title: 'Section',
      blocks: [{ type: 'paragraph', text: 'nested body' }],
    }
    const inner = walk(render(nested, chat)).styles.find((s) => s.lineHeight === 26)
    expect(inner).toBeDefined()
    expect(inner?.fontFamily).toBeUndefined() // sans, not the paper serif
  })
})

/* ── 3. the two-phase floor (charter D8/D9) ─────────────────────────────────── */

function assistantRow(m: Partial<ChatMessage>): Row {
  return { key: 'm-1', kind: 'message', message: { seq: 1, role: 'assistant', ...m } }
}

describe('two-phase floor: plain tail, blocks at settle', () => {
  const blocks = [{ type: 'paragraph', text: 'settled' }]

  it('the streaming tail is plain text at EVERY prefix — no partial-markdown path', () => {
    const full = '**bold** and `code` and\n\n- a list\n\n```js\nx\n```'
    for (let i = 1; i <= full.length; i++) {
      const row: Row = { key: 'tail', kind: 'tail', text: full.slice(0, i) }
      const body = bodyRender(row)
      expect(body.kind).toBe('text')
      // Verbatim: the tail is never re-parsed, reflowed or partially marked up.
      expect(body).toEqual({ kind: 'text', text: full.slice(0, i) })
    }
  })

  it('the settled row swaps that tail for the server-converted blocks', () => {
    expect(bodyRender(assistantRow({ blocks, source_markdown: '**settled**' }))).toEqual({
      kind: 'blocks',
      blocks,
    })
  })

  it('a local echo is the user speaking — always plain', () => {
    expect(bodyRender({ key: 'l-0', kind: 'local', content: '**mine**', queued: true })).toEqual({
      kind: 'text',
      text: '**mine**',
    })
  })

  it('an assistant turn without usable blocks falls back to the markdown source', () => {
    for (const blocksField of [undefined, [], null, {}, 'nope']) {
      const row = assistantRow({
        blocks: blocksField as ChatMessage['blocks'],
        source_markdown: '  plain text  ',
      })
      expect(bodyRender(row)).toEqual({ kind: 'text', text: 'plain text' })
    }
  })

  it('messageBlocks is the runtime gate the declared type cannot enforce', () => {
    expect(messageBlocks({ seq: 1, role: 'assistant', blocks })).toEqual(blocks)
    for (const junk of [undefined, [], null, {}, 'nope', 0]) {
      expect(
        messageBlocks({ seq: 1, role: 'assistant', blocks: junk as ChatMessage['blocks'] }),
      ).toBeUndefined()
    }
  })

  it('user bubbles NEVER render blocks — even if the server sends them (#6126)', () => {
    const row: Row = {
      key: 'm-2',
      kind: 'message',
      message: { seq: 2, role: 'user', blocks, source_markdown: 'what I typed' },
    }
    expect(bodyRender(row)).toEqual({ kind: 'text', text: 'what I typed' })
  })

  it('tool / todo / thinking rows keep their provenance line this slice (S3 owns them)', () => {
    for (const role of ['tool', 'todo', 'thinking']) {
      const row: Row = {
        key: 'm-3',
        kind: 'message',
        message: { seq: 3, role, blocks, source_markdown: 'Read(app.js)' },
      }
      expect(bodyRender(row)).toEqual({ kind: 'text', text: 'Read(app.js)' })
    }
  })
})

/* ── 4. live mermaid in chat + the three rings, unmoved ─────────────────────── */

describe('live mermaid in the transcript', () => {
  // The wire truth: FromMarkdown turns a ```mermaid fence into a block of
  // type "diagram" — never "mermaid".
  const fence = {
    type: 'diagram',
    source: 'flowchart TD\n  A[Ask] --> B[Answer]',
    caption: 'Figure 1. The turn.',
  }

  it('the wire type is "diagram", and only "diagram" is registered', () => {
    expect(BLOCK_RENDERERS.diagram).toBeDefined()
    expect(BLOCK_RENDERERS.mermaid).toBeUndefined()
  })

  it('a mermaid fence in an assistant turn mounts a live island', () => {
    const w = walk(render(fence, chat))
    expect(w.islands).toHaveLength(1)
    expect(w.islands[0]?.source).toBe(fence.source)
    expect(w.text).toContain('Figure 1.')
  })

  it('the island is NOT register-threaded — it keeps its card chrome (D22)', () => {
    const inChat = walk(render(fence, chat)).islands[0]
    const inPaper = walk(render(fence, paperDefault)).islands[0]
    expect(inChat).toEqual(inPaper)
    expect((inChat as { register?: unknown }).register).toBeUndefined()
  })

  it('island theming is isDark-driven, not hex-sniffed', () => {
    expect(islandHtml(fence.source, light)).toContain("theme: false ? 'dark' : 'neutral'")
    expect(islandHtml(fence.source, dark)).toContain("theme: true ? 'dark' : 'neutral'")
  })

  it('the three rings hold under the chat register, byte for byte', () => {
    const hostile = 'A --> B\n</script><script>alert(1)</script>'
    // The island document is a function of (source, theme) ONLY — the chat
    // register cannot reach it — so the rings are the same document paper
    // gets. Asserted here so a future register-threading edit trips this.
    const w = walk(render({ type: 'diagram', source: hostile }, chat))
    const islandSource = w.islands[0]?.source as string
    const islandTheme = w.islands[0]?.theme as Theme
    const html = islandHtml(islandSource, islandTheme)

    expect(html.match(/<\/script>/g)).toHaveLength(2) // ring 1: escaping held
    expect(html).toContain('\\u003c')
    expect(html).not.toContain('alert(1)</script>')
    expect(html).toContain('Content-Security-Policy') // ring 2: CSP meta
    expect(html).toContain("script-src https://cdn.jsdelivr.net 'unsafe-inline'")
    expect(html).toContain("securityLevel:'strict'")
    // Ring 3 (onShouldStartLoadWithRequest) lives on the WebView element the
    // island mounts; it is unreachable from the register by construction.
  })
})
