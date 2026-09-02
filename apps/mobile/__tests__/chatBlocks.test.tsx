// The chat register + the two-phase floor (t3w2-s2-blocks-in-chat).
//
// Three laws are pinned here, all of them things a future edit could break
// silently:
//
//   1. REGISTER DEFAULT — `register` is an optional BlockCtx field and
//      `undefined` IS `'paper'`. The paper reader builds its ctx without the
//      field (PaperReaderScreen.tsx), so this is the non-regression pin for
//      the whole 36-case paperRenderer suite: byte-identical output.
//   2. THE TWO-PHASE FLOOR (chat-TUI charter D8/D9) — the live streaming tail is
//      always plain text; blocks appear only when the turn settles. There is
//      no third state, so a half-written `**bold` cannot flash as markup.
//   3. THE ISLAND'S SECURITY RINGS hold under the chat register exactly as
//      they do under paper — the register never reaches MermaidIsland
//      (charter D22), so its CSP / securityLevel / escaping are unmoved.
//
// Like paperRenderer.test.tsx this walks the element trees the PURE block
// renderers return — no native host.
import type { ReactElement, ReactNode } from 'react'

import {
  anyRenderableBlocks,
  bodyRender,
  CardRow,
  chatBlockCtx,
  TranscriptRow,
  type BodyRow,
  type Row,
} from '../src/screens/ChatSessionScreen'
import { messageBlocks, type ChatMessage } from '../src/chat/wire'
import { MermaidIsland, islandHtml } from '../src/papers/portabledoc/MermaidIsland'
import { BLOCK_RENDERERS, DEGRADE_ONLY, renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { dark, light, type Theme } from '../src/ui/theme'
import { roles, scale } from '../src/ui/typography'

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

/** RN's ScrollView is the element type imported by the renderers; identify it
 * structurally (a `contentContainerStyle` prop) so this does not depend on how
 * the jest-expo preset mocks the native component. */
function isScrollView(node: ReactNode): boolean {
  return isElement(node) && 'contentContainerStyle' in (node.props as object)
}

function findScrollView(node: ReactNode): ReactNode | undefined {
  if (Array.isArray(node)) {
    for (const child of node) {
      const hit = findScrollView(child as ReactNode)
      if (hit !== undefined) return hit
    }
    return undefined
  }
  if (!isElement(node)) return undefined
  if (isScrollView(node)) return node
  return findScrollView((node.props as { children?: ReactNode }).children)
}

function countHorizontalScrollers(node: ReactNode): number {
  if (Array.isArray(node)) {
    return node.reduce<number>((n, c) => n + countHorizontalScrollers(c as ReactNode), 0)
  }
  if (!isElement(node)) return 0
  const props = node.props as { horizontal?: boolean; children?: ReactNode }
  const self = isScrollView(node) && props.horizontal === true ? 1 : 0
  return self + countHorizontalScrollers(props.children)
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
    // The lead is asserted against the TOKEN, not re-derived from the ×1.3
    // formula: S8 moved that law into typography.ts (paperH1/H2/H3 are the
    // formula, rounded), so re-deriving it here would let the render and the
    // token module drift apart by up to half a pixel and still pass.
    for (const [level, step, marginTop] of [
      [1, roles.paperH1, 24],
      [2, roles.paperH2, 20],
      [3, roles.paperH3, 16],
    ] as const) {
      expect(rootStyle(render({ type: 'heading', level, text: 'h' }, paperDefault))).toMatchObject({
        fontSize: step.fontSize,
        marginTop,
        lineHeight: step.lineHeight,
      })
      expect(step.lineHeight).toBe(Math.round(step.fontSize * 1.3))
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
    for (const [level, step, marginTop] of [
      [1, roles.chatH1, 16],
      [2, roles.chatH2, 14],
      [3, roles.chatH3, 12],
    ] as const) {
      const s = rootStyle(render({ type: 'heading', level, text: 'h' }, chat))
      expect(s).toMatchObject({ fontSize: step.fontSize, marginTop, lineHeight: step.lineHeight })
      expect(step.lineHeight).toBe(Math.round(step.fontSize * 1.3))
      // Strictly tighter than the paper register at every level.
      const paper = rootStyle(render({ type: 'heading', level, text: 'h' }, paperDefault))
      expect(step.fontSize).toBeLessThan(paper.fontSize as number)
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

/* ── 2a. the code block's language header (bl-frommarkdown-fence-language) ─── */

// The converter now carries a fence's info string onto the block as `lang`
// (FromMarkdown.code_block/2), so ```python finally arrives here as something
// to show. Two laws, and the second is the one that keeps this additive:
//
//   1. WITH a lang, the label is DRAWN and it is not inside the scroller — a
//      label that scrolls away with the code is not a label.
//   2. WITHOUT a lang, the rendered tree is byte-identical to what it was
//      before the header existed. Asserted as a JSON comparison against a
//      literal-shaped expectation rather than by eyeballing the style, because
//      a wrapper View added around the no-lang case changes `rootStyle`'s
//      answer for every other code assertion in this file.

describe("the code block's language header", () => {
  for (const [name, ctx] of [
    ['paper', paperDefault],
    ['chat', chat],
  ] as const) {
    it(`${name}: a lang is drawn as a header above the code`, () => {
      const w = walk(render({ type: 'code', value: 'print(1)', lang: 'python' }, ctx))
      expect(w.text).toContain('python')
      expect(w.text).toContain('print(1)')
    })

    it(`${name}: the header sits OUTSIDE the horizontal scroller`, () => {
      const node = render({ type: 'code', value: 'print(1)', lang: 'python' }, ctx)
      if (!isElement(node)) throw new Error('expected an element')

      // The root is the frame-carrying WRAPPER, not the scroller itself —
      // without this line the rest of the test passes vacuously on a renderer
      // that never drew a header at all (the scroller would then BE the root
      // and trivially hold only the code).
      expect(isScrollView(node)).toBe(false)
      expect(rootStyle(node).marginVertical).toBe(10)

      // …and the label is a direct child of that wrapper, not a descendant of
      // the ScrollView.
      const scroller = findScrollView(node)
      expect(scroller).toBeDefined()
      expect(walk(scroller as ReactNode).text).toBe('print(1)')
      expect(walk(scroller as ReactNode).text).not.toContain('python')

      // …and still exactly ONE horizontal scroller (charter D50).
      expect(countHorizontalScrollers(node)).toBe(1)
    })

    it(`${name}: no lang renders EXACTLY the pre-header tree`, () => {
      const withoutKey = JSON.stringify(render({ type: 'code', value: 'print(1)' }, ctx))

      // The frame lives on the ScrollView itself — the wrapper View that the
      // lang case introduces must not appear here.
      const node = render({ type: 'code', value: 'print(1)' }, ctx)
      if (!isElement(node)) throw new Error('expected an element')
      expect(isScrollView(node)).toBe(true)
      expect((node.props as { horizontal?: boolean }).horizontal).toBe(true)
      expect(rootStyle(node).marginVertical).toBe(10)
      expect(walk(node).text).toBe('print(1)')

      // A blank / whitespace-only / non-string lang is the SAME no-lang tree —
      // put_if_present drops a blank lang on the write path, but a hand-authored
      // block or an older row can still carry one.
      for (const lang of ['', '   ', null, undefined, 42, {}]) {
        expect(JSON.stringify(render({ type: 'code', value: 'print(1)', lang }, ctx))).toBe(
          withoutKey,
        )
      }
    })
  }

  it('the label is quiet chrome, not code — muted, smaller than the code text', () => {
    const w = walk(render({ type: 'code', value: 'print(1)', lang: 'python' }, paperDefault))
    const label = w.styles.find((s) => s.fontSize === scale.micro.fontSize)
    expect(label).toBeDefined()
    expect(label?.color).toBe(theme.textMuted)
    expect(label?.lineHeight).toBe(scale.micro.lineHeight)
    expect(label?.fontSize as number).toBeLessThan(roles.codeBlock.fontSize)
  })
})

/* ── 2b. the SCREEN-SIDE wiring ─────────────────────────────────────────────── */

// The register laws above all prove what the renderer DOES when handed a chat
// ctx. These prove the transcript actually hands it one — the gap an
// adversarial review found: two one-line deletions that left every other test
// green while removing the whole feature.

describe('screen wiring (the register actually reaches the transcript)', () => {
  it('chatBlockCtx binds the chat register — deleting it demotes turns to serif', () => {
    const ctx = chatBlockCtx(theme, 'https://guerrilla.barkpark.cloud')
    expect(ctx.register).toBe('chat')
    expect(ctx.serverBase).toBe('https://guerrilla.barkpark.cloud')
    expect(ctx.theme).toBe(theme)
    // The consequence, not just the flag: a paragraph rendered under the ctx
    // the SCREEN builds is sans at the assistant measure, never paper serif.
    const s = rootStyle(render({ type: 'paragraph', text: 'x' }, ctx))
    expect(s.fontFamily).toBeUndefined()
    expect(s.fontSize).toBe(16)
    expect(s.lineHeight).toBe(26)
  })

  it('serverBase is optional — a ctx without one still carries the register', () => {
    expect(chatBlockCtx(theme)).toEqual({ theme, serverBase: undefined, register: 'chat' })
  })

  it('TranscriptRow RENDERS an assistant turn as blocks, not as text', () => {
    const row = assistantRow({
      blocks: [
        { type: 'heading', level: 2, text: 'Heading' },
        { type: 'paragraph', text: 'body copy' },
        { type: 'code', value: 'pnpm test' },
      ],
      source_markdown: '## Heading\n\nbody copy\n\n```\npnpm test\n```',
    })
    const w = walk(
      TranscriptRow({
        row,
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    // The rendered tree carries the block content…
    for (const s of ['Heading', 'body copy', 'pnpm test']) expect(w.text).toContain(s)
    // …and NOT the raw markdown source it was built from: if the blocks
    // branch is bypassed the fallback paints the fence markers verbatim.
    expect(w.text).not.toContain('##')
    expect(w.text).not.toContain('```')
    // The chat register reached the leaf through the screen, not just the test.
    expect(w.styles.some((s) => s.fontSize === 16 && s.lineHeight === 26)).toBe(true)
  })

  it('TranscriptRow keeps a blockless assistant turn as plain text', () => {
    const w = walk(
      TranscriptRow({
        row: assistantRow({ source_markdown: 'just words' }),
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toBe('just words')
  })
})

/* ── 3. the two-phase floor (chat-TUI charter D8/D9) ────────────────────────── */

function assistantRow(m: Partial<ChatMessage>): BodyRow {
  return { key: 'm-1', kind: 'message', message: { seq: 1, role: 'assistant', ...m } }
}

describe('two-phase floor: plain tail, blocks at settle', () => {
  const blocks = [{ type: 'paragraph', text: 'settled' }]

  // NARROWED DELIBERATELY (mob-w3-rich-tail, charter D59), and the narrowing is
  // named in the PR rather than left for a reader to notice.
  //
  // What it used to say: "the whole tail is plain at every prefix". That claim
  // stopped being the law when the SERVER started settling the answer in
  // segments — but worse, it had already stopped being CHECKED where it matters:
  // this arm of bodyRender is dead code for the UI (TranscriptRow returns the
  // tail's Text before it ever calls bodyRender), which is why mob-rt-s3 had to
  // go and pin the plain-tail law on the arm that actually paints, in
  // chatMotion.test.tsx §6. Left as it was, this loop would have kept asserting
  // a decoy: green through any change to what the reader sees.
  //
  // What it says now: the UNSETTLED REMAINDER is plain at every prefix. That is
  // the whole of the original anti-flash intent — a half-written `**bold` marker
  // can never flash as markup, because the row that carries it holds a STRING and
  // has no blocks field to render — and it is the part that survives the
  // progressive tail, since the row's text is now the remainder rather than the
  // whole turn. What is settled is a document; what is unfinished is plain.
  it('the unsettled REMAINDER is plain text at EVERY prefix — no partial-markdown path', () => {
    const full = '**bold** and `code` and\n\n- a list\n\n```js\nx\n```'
    for (let i = 1; i <= full.length; i++) {
      const row: BodyRow = { key: 'tail', kind: 'tail', text: full.slice(0, i) }
      const body = bodyRender(row)
      expect(body.kind).toBe('text')
      // Verbatim: the remainder is never re-parsed, reflowed or partially marked up.
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

  // THE ZERO-RENDERABLE-BLOCKS TURN. Per BLOCK, an unknown type degrading to a
  // labeled dashed box is right — a mixed turn shows what it has and is honest
  // about the one thing this client is too old to draw. Per TURN it is a
  // failure: a turn whose blocks are ALL unknown paints a stack of dashed boxes
  // and no answer, while the full text of that answer sits unused in
  // source_markdown on the very same row. So the turn-level decision is made
  // screen-side, against the registry renderBlockNative itself dispatches on —
  // blocks.tsx, reducer.ts and wire.ts are untouched.
  it('a turn whose blocks are ALL unrenderable falls back to source_markdown', () => {
    const bogus = [
      { type: 'chat-hologram', frames: 3 },
      { type: 'quantum-callout', text: 'from a newer server' },
    ]
    expect(anyRenderableBlocks(bogus)).toBe(false)
    expect(bodyRender(assistantRow({ blocks: bogus, source_markdown: '  the answer  ' }))).toEqual({
      kind: 'text',
      text: 'the answer',
    })
  })

  it('ONE renderable block keeps the whole turn on the document path', () => {
    // The mixed turn: the paragraph paints and the stray block keeps its own
    // per-block dashed fallback. Falling the whole turn back to markdown here
    // would throw away a turn the client can very nearly draw.
    const mixed = [{ type: 'paragraph', text: 'settled' }, { type: 'chat-hologram', frames: 3 }]
    expect(anyRenderableBlocks(mixed)).toBe(true)
    expect(bodyRender(assistantRow({ blocks: mixed, source_markdown: 'raw' }))).toEqual({
      kind: 'blocks',
      blocks: mixed,
    })
  })

  it('the renderable test IS the dispatcher’s own registry — it cannot disagree', () => {
    // Not a hand-kept list: every key renderBlockNative would dispatch counts,
    // including the six typed chat-* rows spread into the same registry. The ONE
    // documented exception — a registered DEGRADE CARD — has its own describe
    // block below; none of the types here is one.
    for (const type of ['paragraph', 'heading', 'diagram', 'chat-tool-diff']) {
      expect(DEGRADE_ONLY.has(type)).toBe(false)
      expect(anyRenderableBlocks([{ type }])).toBe(BLOCK_RENDERERS[type] !== undefined)
    }
    expect(anyRenderableBlocks([])).toBe(false)
  })

  it('the rendered row PAINTS the answer text, not a stack of dashed boxes', () => {
    // One level above bodyRender, where a regression would actually land: a row
    // that resolves to text and then renders blocks anyway passes the pins above.
    const row = assistantRow({
      blocks: [{ type: 'chat-hologram', frames: 3 }],
      source_markdown: 'The migration is done.',
    })
    const w = walk(
      TranscriptRow({
        row,
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toBe('The migration is done.')
    expect(w.text).not.toContain('chat-hologram') // no dashed provenance box
  })

  it('an all-unrenderable CARD keeps its shell and shows the markdown body', () => {
    // A card asks for a decision. Presenting that decision as a dashed box is
    // the one place the per-block degrade becomes unanswerable — the frame and
    // the Allow/Deny footer are the envelope's either way (D35).
    // CardRow directly: TranscriptRow delegates to it as an ELEMENT, and this
    // walk reads returned trees rather than mounting them.
    const w = walk(
      CardRow({
        m: {
          seq: 9,
          role: 'approval',
          blocks: [{ type: 'quantum-callout', text: 'x' }],
          source_markdown: 'Run `rm -rf build`?',
          metadata: { request_id: 'req-1', approval_status: 'pending' },
        },
        theme,
        blockCtx: chatBlockCtx(theme),
        inFlight: {},
        onAnswer: () => {},
      }),
    )
    expect(w.text).toContain('Run `rm -rf build`?')
    expect(w.text).toContain('Allow')
    expect(w.text).toContain('Deny')
  })

  /* ── the DEGRADE_ONLY seam (charter D47) ──────────────────────────────────── */

  // THE HIGH-FLIP-RISK JUDGMENT of the tail slice, pinned where it can actually
  // fail. `video` and `asciicast` gained renderers in mob-zb-s7 — but degrade
  // CARDS, labeled boxes that state their ceiling rather than play anything. The
  // turn-level test above derives "is this turn worth the document path?" from
  // the registry, so registering those two would have flipped a turn made of
  // NOTHING BUT them off the text path it takes today: instead of the full
  // `source_markdown` the answer arrived with, the transcript would paint two
  // summary cards. That is a strict information LOSS, caused by adding a
  // renderer, invisible to every per-block test — so the subtraction is pinned
  // three ways: the set's members are really registered (otherwise the
  // subtraction is guarding nothing), the turn-level answer is false ANYWAY, and
  // the rendered row still carries the answer.
  describe('DEGRADE_ONLY: registering a degrade card must not flip a turn', () => {
    const degrade = [...DEGRADE_ONLY]

    it('names exactly the two degrade cards, and every one of them IS registered', () => {
      expect(degrade.sort()).toEqual(['asciicast', 'video'])
      // This is the assertion that makes the next one non-vacuous: if these
      // types were simply unregistered, `anyRenderableBlocks` would answer false
      // for the boring reason and the subtraction below could be deleted without
      // a single test going red.
      for (const type of degrade) expect(BLOCK_RENDERERS[type]).toBeDefined()
    })

    it('a degrade-only turn answers FALSE and keeps the FULL source_markdown', () => {
      // Drop the `!DEGRADE_ONLY.has(...)` clause from anyRenderableBlocks and
      // this is the test that reds.
      for (const type of degrade) expect(anyRenderableBlocks([{ type }])).toBe(false)
      expect(anyRenderableBlocks(degrade.map((type) => ({ type })))).toBe(false)

      const answer = '## Deploy\n\nThe cast below shows the rollout, which took 4m12s end to end.'
      const row = assistantRow({
        blocks: [
          { type: 'video', src: 'https://x.test/rollout.mp4' },
          { type: 'asciicast', src: 'https://x.test/rollout.cast' },
        ],
        source_markdown: answer,
      })
      expect(bodyRender(row)).toEqual({ kind: 'text', text: answer })

      // One level up, where the regression would actually land: the row paints
      // the answer, not the two cards that would have replaced it.
      const w = walk(
        TranscriptRow({ row, theme, blockCtx: chatBlockCtx(theme), inFlight: {}, onAnswer: () => {} }),
      )
      expect(w.text).toBe(answer)
      expect(w.text).not.toContain('▶ Video')
      expect(w.text).not.toContain('▶ Asciicast')
    })

    it('a MIXED turn still takes the blocks path — and the card draws there', () => {
      // The other half of the law: the subtraction is TURN-level only. Gating the
      // dispatch instead would cost the mixed turn its card and replace it with
      // an "Unsupported block" box, which is a lie about a type we support.
      const mixed = [
        { type: 'paragraph', text: 'The rollout is done.' },
        { type: 'video', src: 'https://x.test/rollout.mp4' },
      ]
      expect(anyRenderableBlocks(mixed)).toBe(true)
      expect(bodyRender(assistantRow({ blocks: mixed, source_markdown: 'raw' }))).toEqual({
        kind: 'blocks',
        blocks: mixed,
      })
      const w = walk(
        TranscriptRow({
          row: assistantRow({ blocks: mixed, source_markdown: 'raw' }),
          theme,
          blockCtx: chatBlockCtx(theme),
          inFlight: {},
          onAnswer: () => {},
        }),
      )
      expect(w.text).toContain('The rollout is done.')
      expect(w.text).toContain('▶ Video')
      expect(w.text).not.toContain('Unsupported block')
    })

    it('a degrade-only CARD row keeps its markdown body too (the second call site)', () => {
      // CardRow reaches anyRenderableBlocks independently of bodyRender, so a fix
      // applied at one call site and not the other would leave an approval asking
      // for a decision behind a video card.
      const w = walk(
        CardRow({
          m: {
            seq: 11,
            role: 'approval',
            blocks: [{ type: 'asciicast', src: 'https://x.test/s.cast' }],
            source_markdown: 'Replay the failed deploy?',
            metadata: { request_id: 'req-2', approval_status: 'pending' },
          },
          theme,
          blockCtx: chatBlockCtx(theme),
          inFlight: {},
          onAnswer: () => {},
        }),
      )
      expect(w.text).toContain('Replay the failed deploy?')
      expect(w.text).not.toContain('▶ Asciicast')
    })
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

  // S3 flipped this: tool / todo / thinking rows now render their typed
  // chat-* block. The two-phase law is unchanged — a row WITHOUT usable blocks
  // still degrades to its provenance text. The blocks leg lives in
  // chatRenderers.test.tsx alongside the renderers it exercises.
  it('a blockless tool / todo / thinking row still degrades to its source line', () => {
    for (const role of ['tool', 'todo', 'thinking']) {
      const row: Row = {
        key: 'm-3',
        kind: 'message',
        message: { seq: 3, role, source_markdown: 'Read(app.js)' },
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
