// The six T1 STRUCTURE NATIVES (mob-zb-s3, charter D46/D50/D52) and the four
// fidelity catch-ups that rode the same slice.
//
// The registry tripwire in chatRenderers.test.tsx already proves these types
// RENDER (no unknown-block fallback). That is a low bar: a renderer returning an
// empty frame passes it. What is pinned HERE is what each block MEANS —
//
//   • status-legend paints the role vocabulary, glyph for glyph, against the
//     cross-surface parity golden. It is the one renderer that reads ZERO block
//     props, so the golden's data-free input is the whole contract.
//   • pipeline lays out one stage CELL per node, `→`-separated, in order.
//   • stage is that same cell standalone, from scalars OR from slots.
//   • card is the ONE slot-recursive structure block: its slots recurse through
//     the shared dispatcher with ctx forwarded WHOLESALE, so a card inside a CHAT
//     turn must speak chat typography — a re-minted ctx literal at the recursion
//     site would silently demote it to the paper serif and nothing else would
//     notice (D50).
//   • task-detail shows the status glyph and the criteria apparatus.
//   • roadmap groups its lanes by phase row and marks today.
//
// Plus the catch-ups, each of which was a LIVE defect: a blank eyebrow, a
// `danger` card indistinguishable from `info`, a dead underlined action label,
// and a serif lede/pull quote leaking into chat turns.
//
// Like the sibling suites this walks the element trees the PURE renderers return
// — no native host, no emulator.
import type { ReactElement, ReactNode } from 'react'
import { Image, Linking, ScrollView } from 'react-native'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// The generator-owned cross-surface parity fixtures, consumed straight from the
// Go testdata mirror (the chatRenderers.test.tsx precedent: an ESM default
// import, strictly test-side, so metro never bundles them into the app).
import cardGolden from '../../../internal/pdrender/testdata/card.golden.json'
import pipelineGolden from '../../../internal/pdrender/testdata/pipeline.golden.json'
import roadmapGolden from '../../../internal/pdrender/testdata/roadmap.golden.json'
import stageGolden from '../../../internal/pdrender/testdata/stage.golden.json'
import statusLegendGolden from '../../../internal/pdrender/testdata/status-legend.golden.json'
import taskDetailGolden from '../../../internal/pdrender/testdata/task-detail.golden.json'

// IMPORT ORDER IS LOAD-BEARING HERE, and the two lines below must not be
// swapped. blocks/core-doc.tsx sits in a cycle with registry.tsx (it imports
// renderBlockNative for the card slot recursion; registry imports its emitter
// map). Entering the cycle at REGISTRY is safe — renderBlockNative is a hoisted
// function declaration, so a family module evaluated mid-cycle still gets a live
// reference. Entering it at a FAMILY MODULE is not: registry's body then runs
// while that module is still half-evaluated, its emitter map is `undefined`, and
// `...undefined` in an object spread is a silent no-op — BLOCK_RENDERERS comes
// out missing the whole family and every one of its types degrades to the
// unknown-block fallback with nothing but a console.warn to show for it. The app
// only ever enters through this barrel (nothing under src/ imports a family
// module directly), which is why the hazard is latent there and was live here.
import {
  BLOCK_RENDERERS,
  renderBlockNative,
  type BlockCtx,
} from '../src/papers/portabledoc/blocks'
import {
  LEGEND_ROLES,
  STATUS_ROLES,
  glyphChar,
  roleOf,
} from '../src/papers/portabledoc/blocks/core-doc'
import { MermaidIsland } from '../src/papers/portabledoc/MermaidIsland'
import { light } from '../src/ui/theme'
import { roles } from '../src/ui/typography'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme = light
const paper: BlockCtx = { theme }
const chat: BlockCtx = { theme, register: 'chat' }
/** The card golden's media src is an absolute https URL, so no server base is
 * needed for it; the reader supplies one in real life and a couple of cases
 * below lean on that path. */
const withBase: BlockCtx = { theme, serverBase: 'https://paper.example' }

/* ── element walking ────────────────────────────────────────────────────────── */

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

interface Walk {
  text: string
  /** Every element's resolved style, arrays merged left-to-right. */
  styles: Record<string, unknown>[]
  /** Every element's component type, in tree order. */
  types: unknown[]
  /** The onPress handlers found, so a "tappable" claim is checkable. */
  presses: (() => void)[]
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
  if (!isElement(node)) return
  const props = node.props as Record<string, unknown>
  acc.types.push(node.type)
  if (node.type === MermaidIsland) return // stateful leaf
  const raw = props.style
  if (raw !== undefined) {
    const parts = Array.isArray(raw) ? raw : [raw]
    acc.styles.push(Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>)
  }
  if (typeof props.onPress === 'function') acc.presses.push(props.onPress as () => void)
  walkNode(props.children as ReactNode, acc)
}

function walk(block: unknown, ctx: BlockCtx = paper): Walk {
  const acc: Walk = { text: '', styles: [], types: [], presses: [] }
  walkNode(renderBlockNative(block, ctx, 0), acc)
  return acc
}

function text(block: unknown, ctx: BlockCtx = paper): string {
  return walk(block, ctx).text
}

/** Every style that sets `key`, in tree order. */
function styleValues(w: Walk, key: string): unknown[] {
  return w.styles.filter((s) => s[key] !== undefined).map((s) => s[key])
}

function count(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1
}

/** The goldens are typed as their literal shapes; the renderers take `unknown`. */
function input(golden: { input: unknown }): unknown {
  return golden.input
}

/* ── 1. status-legend — the vocabulary IS the content ───────────────────────── */

describe('status-legend paints the role vocabulary', () => {
  const legend = walk(input(statusLegendGolden))

  it('paints every row of the cross-surface golden — glyph, label and meaning', () => {
    expect(statusLegendGolden.expected.rows).toHaveLength(8)
    for (const row of statusLegendGolden.expected.rows) {
      expect(legend.text).toContain(row.label)
      // The spinner role's web glyph is '' (a CSS ::before animates it there).
      // RN has no such hook, so it paints the static frame mobile already ships
      // for in_progress; every OTHER role is the golden's glyph verbatim.
      const expectedGlyph = row.spinner ? '◐' : row.glyph
      expect(glyphChar(row.role)).toBe(expectedGlyph)
      expect(legend.text).toContain(expectedGlyph)
    }
    // The meanings are content too, not decoration.
    expect(legend.text).toContain('claim it now')
    expect(legend.text).toContain('abandoned or superseded')
  })

  it('holds the fail-open `unknown` sentinel OUT of the legend key', () => {
    expect(STATUS_ROLES).toHaveLength(9)
    expect(LEGEND_ROLES).toHaveLength(8)
    expect(LEGEND_ROLES.map((r) => r.role)).not.toContain('unknown')
    expect(legend.text).not.toContain('unrecognized status')
    // …while roleOf still RESOLVES it, so a stray status never masquerades as
    // `open`'s bright circle (D11).
    expect(roleOf('marinating')).toBe('unknown')
    expect(roleOf('')).toBe('open')
    expect(roleOf('closed')).toBe('done')
  })

  it('reads ZERO block props — junk fields cannot change what it paints', () => {
    expect(text({ type: 'status-legend', items: ['nope'], title: 'ignored', snapshot: [] })).toBe(legend.text)
  })
})

/* ── 2 + 3. pipeline and stage ──────────────────────────────────────────────── */

describe('pipeline renders one stage cell per node, in order', () => {
  const pipe = walk(input(pipelineGolden))
  const nodes = pipelineGolden.expected.nodes

  it('one cell per node, `→`-separated', () => {
    expect(nodes).toHaveLength(3)
    // The pipe cell is the ONLY thing carrying the fixed cell width, so counting
    // it counts cells — an empty frame or a collapsed row cannot fake this.
    expect(styleValues(pipe, 'width').filter((w) => w === 168)).toHaveLength(3)
    expect(count(pipe.text, '→')).toBe(nodes.length - 1)
  })

  it('every node field reaches the cell, and the order is the authored order', () => {
    for (const n of nodes) {
      expect(pipe.text).toContain(n.title)
      expect(pipe.text).toContain(n.detail)
      expect(pipe.text).toContain(n.kind)
    }
    expect(pipe.text.indexOf('Ingest')).toBeLessThan(pipe.text.indexOf('Transform'))
    expect(pipe.text.indexOf('Transform')).toBeLessThan(pipe.text.indexOf('Publish'))
    // The provenance string is a line of its own; `source: true` contributes no
    // text at all (it is the origin RULE), and the third node has neither.
    expect(pipe.text).toContain('queue.ex:42')
    expect(pipe.text).not.toContain('true')
  })

  it('scrolls horizontally rather than stacking — order is the whole point', () => {
    expect(pipe.types[0]).toBe(ScrollView)
  })

  it('an empty pipeline renders nothing', () => {
    expect(renderBlockNative({ type: 'pipeline', nodes: [] }, paper, 0)).toBeNull()
  })
})

describe('stage is the per-node cell, standalone', () => {
  const stage = walk(input(stageGolden))
  const expected = stageGolden.expected

  it('paints kind, title and detail from SCALARS', () => {
    expect(stage.text).toContain(expected.kind)
    expect(stage.text).toContain(expected.title)
    expect(stage.text).toContain(expected.detail)
  })

  it('wears the origin rule when `source` is true, and carries no source text', () => {
    expect(expected.source_role).toBe('origin')
    expect(expected.source_text).toBe('')
    const frame = stage.styles[0]!
    expect(frame.borderLeftWidth).toBe(3)
    expect(frame.borderLeftColor).toBe(theme.accent)
    // A plain cell keeps the neutral hairline.
    const plain = walk({ type: 'stage', kind: 'gate', title: 'Review' }).styles[0]!
    expect(plain.borderLeftWidth).toBe(1)
    expect(plain.borderLeftColor).toBe(theme.border)
  })

  it('takes SLOT-materialized fields when they are present, scalars otherwise', () => {
    const slotted = text({
      type: 'stage',
      kind: 'scalar-kind',
      title: 'scalar-title',
      slots: {
        title: [{ text: 'slot ' }, { text: 'title' }],
      },
    })
    expect(slotted).toContain('slot title')
    expect(slotted).not.toContain('scalar-title')
    // An EMPTY slot does not win — the scalar still shows.
    expect(slotted).toContain('scalar-kind')
  })

  it('renders the files line in mono', () => {
    const w = walk({ type: 'stage', title: 'Review', files: 'lib/queue.ex' })
    expect(w.text).toContain('lib/queue.ex')
    expect(styleValues(w, 'fontFamily')).toContain('monospace')
  })
})

/* ── 4. card — the ONE slot-recursive structure block ───────────────────────── */

describe('card recurses its slots through the shared dispatcher', () => {
  const card = walk(input(cardGolden), withBase)

  it('renders all four slots, in media/title/body/action order', () => {
    expect(cardGolden.expected.slots).toEqual(['media', 'title', 'body', 'action'])
    expect(card.text).toContain('Card title')
    expect(card.text).toContain('Card body text.')
    expect(card.text).toContain('Open the board')
    expect(card.text.indexOf('Card title')).toBeLessThan(card.text.indexOf('Card body text.'))
    expect(card.text.indexOf('Card body text.')).toBeLessThan(card.text.indexOf('Open the board'))
    expect(card.text).not.toContain('Unsupported block')
  })

  it('coerces a BARE-MAP media element to an image (the normalizeMedia fast path)', () => {
    expect(cardGolden.expected.media_fastpath).toBe(true)
    const bare = walk(
      {
        type: 'card',
        slots: { media: [{ src: 'https://cdn.example.com/cover.png', alt: 'Cover art' }] },
      },
      withBase,
    )
    expect(bare.types).toContain(Image)
    expect(bare.text).not.toContain('Unsupported block')
    // A slot element that already declares its type passes through untouched.
    const typed = walk({ type: 'card', slots: { media: [{ type: 'paragraph', text: 'not an image' }] } })
    expect(typed.text).toContain('not an image')
    expect(typed.types).not.toContain(Image)
  })

  it('forwards ctx WHOLESALE — a card in a CHAT turn speaks chat typography', () => {
    const body = { type: 'paragraph', text: 'recursed prose' }
    const inChat = walk({ type: 'card', slots: { body: [body] } }, chat)
    const inPaper = walk({ type: 'card', slots: { body: [body] } }, paper)
    expect(inChat.text).toContain('recursed prose')
    // The recursed paragraph resolves the register's own body measure. If the
    // recursion re-minted a ctx literal, the register would be dropped and BOTH
    // of these would come back as the paper serif.
    expect(inChat.styles).toContainEqual(expect.objectContaining(roles.chatBody))
    expect(styleValues(inChat, 'fontFamily')).not.toContain('serif')
    expect(styleValues(inPaper, 'fontFamily')).toContain('serif')
  })

  it('paints tone as a left-border tint — danger is NOT info', () => {
    const tint = (tone: string) => walk({ type: 'card', tone, slots: {} }).styles[0]!.borderLeftColor
    expect(tint('info')).toBe(theme.accent)
    expect(tint('ok')).toBe(theme.success)
    expect(tint('warn')).toBe(theme.warn)
    expect(tint('danger')).toBe(theme.danger)
    expect(tint('danger')).not.toBe(tint('info'))
    // No tone / an unknown tone keeps the neutral frame.
    expect(tint('')).toBe(theme.border)
    expect(tint('chartreuse')).toBe(theme.border)
    expect(walk({ type: 'card', tone: 'danger', slots: {} }).styles[0]!.borderLeftWidth).toBe(3)
    expect(walk({ type: 'card', slots: {} }).styles[0]!.borderLeftWidth).toBe(1)
  })
})

/* ── 5. task-detail ────────────────────────────────────────────────────────── */

describe('task-detail is the premium detail card', () => {
  const detail = walk(input(taskDetailGolden))
  const expected = taskDetailGolden.expected

  it('leads with the title and the status glyph + meta line', () => {
    expect(detail.text).toContain(expected.title)
    expect(detail.text).toContain(glyphChar('progress')) // in_progress → progress
    expect(detail.text).toContain('in_progress · P1')
  })

  it('shows the criteria tally, every criterion, and the evidence beneath it', () => {
    expect(detail.text).toContain(`Criteria · ${expected.criteria.met}/${expected.criteria.total}`)
    expect(detail.text).toContain('Gen emits fixtures')
    expect(detail.text).toContain('Web realizes the projection')
    // A met criterion wears the done glyph, an unmet one the ready circle.
    expect(detail.text).toContain('✓')
    expect(detail.text).toContain('○')
    const withEvidence = text({
      type: 'task-detail',
      task: { title: 'T', criteria: [{ met: true, criterion: 'gate green', evidence: 'exit 0' }] },
    })
    // `criterion` is read when `text` is absent — the bp task doc's own field name.
    expect(withEvidence).toContain('gate green')
    expect(withEvidence).toContain('↳ exit 0')
  })

  it('walks the timeline in order, each segment with its role glyph', () => {
    for (const seg of expected.timeline) {
      expect(detail.text).toContain(seg.label)
      expect(detail.text).toContain(glyphChar(seg.role))
    }
    expect(count(detail.text, '→')).toBe(expected.timeline.length - 1)
    expect(detail.text.indexOf('Filed')).toBeLessThan(detail.text.indexOf('Shipped'))
  })

  it('renders the stamp, dependency, rail and label sections only when populated', () => {
    expect(expected.sections).toEqual(['meta', 'timeline', 'criteria', 'labels'])
    // The golden task has no stamp/deps/rails, and none of those labels appear.
    expect(detail.text).not.toContain('created')
    expect(detail.text).not.toContain('Dependencies')
    expect(detail.text).not.toContain('Children')
    expect(detail.text).toContain('parity · w5')

    const full = text({
      type: 'task-detail',
      task: {
        title: 'T',
        created: '2026-07-01',
        updated: '2026-07-26',
        description: 'the prose body',
        blocks: 1,
        blocked_by: 2,
        children: [{ title: 'kid a', status: 'done' }, { title: 'kid b', status: 'open' }],
        papers: ['/papers/one'],
      },
    })
    expect(full).toContain('created 2026-07-01 · updated 2026-07-26')
    expect(full).toContain('the prose body')
    expect(full).toContain('blocks 1 task · blocked by 2')
    expect(full).toContain('Children · 1/2 done')
    expect(full).toContain('▸ /papers/one')
  })

  it('caps the papers rail at 10 and says how many it withheld', () => {
    const papers = Array.from({ length: 13 }, (_, i) => `/papers/p${i}`)
    const w = text({ type: 'task-detail', task: { title: 'T', papers } })
    expect(w).toContain('/papers/p9')
    expect(w).not.toContain('/papers/p10')
    expect(w).toContain('… and 3 more')
  })

  it('renders NOTHING for a title-less task (editor scaffolding, not a hole)', () => {
    expect(renderBlockNative({ type: 'task-detail', task: { status: 'open' } }, paper, 0)).toBeNull()
    expect(renderBlockNative({ type: 'task-detail' }, paper, 0)).toBeNull()
    // The task fields may sit on the BLOCK itself rather than under `task`.
    expect(text({ type: 'task-detail', title: 'flat shape', status: 'done' })).toContain('flat shape')
  })
})

/* ── 6. roadmap ────────────────────────────────────────────────────────────── */

describe('roadmap groups its lanes and marks today', () => {
  const rm = walk(input(roadmapGolden))

  it('renders the scale, every lane, and the phase lane as the group header', () => {
    for (const tick of roadmapGolden.expected.scale) expect(rm.text).toContain(tick)
    const [phase, item] = roadmapGolden.expected.lanes
    expect(phase!.phase).toBe(true)
    expect(item!.phase).toBe(false)
    expect(rm.text).toContain(phase!.title)
    expect(rm.text).toContain(item!.title)
    // The group header is the emphasized row; its items are indented under it.
    expect(styleValues(rm, 'paddingLeft')).toContain(12)
    expect(styleValues(rm, 'fontWeight')).toContain('700')
  })

  it('marks today, both as a caption and as a rule inside every track', () => {
    const withToday = walk({
      type: 'roadmap',
      today: 55,
      snapshot: [{ title: 'a', left: 0, width: 40 }, { title: 'b', left: 40, width: 30 }],
    })
    expect(withToday.text).toContain('today · 55%')
    const marks = withToday.styles.filter((s) => s.width === 2 && s.left === '55%')
    expect(marks).toHaveLength(2) // one per track, so it lines up down the column
    // No `today` field → no marker at all (never an invented "now").
    const noToday = walk({ type: 'roadmap', snapshot: [{ title: 'a', left: 0, width: 40 }] })
    expect(noToday.text).not.toContain('today')
    expect(noToday.styles.filter((s) => s.width === 2)).toHaveLength(0)
  })

  it('keeps a lane that starts at the left edge (left: 0 is a value, not a blank)', () => {
    // model.num() rejects 0, which would have silently dropped the span of every
    // lane starting at the origin — the clamp here reads raw numbers instead.
    const w = walk({ type: 'roadmap', snapshot: [{ title: 'origin lane', left: 0, width: 40 }] })
    expect(w.text).toContain('origin lane')
    expect(styleValues(w, 'left')).toContain('0%')
    expect(styleValues(w, 'width')).toContain('40%')
    // A missing width spans to the right edge; an oversized one is clamped.
    expect(styleValues(walk({ type: 'roadmap', snapshot: [{ title: 'a', left: 60 }] }), 'width')).toContain('40%')
    expect(
      styleValues(walk({ type: 'roadmap', snapshot: [{ title: 'a', left: 60, width: 90 }] }), 'width'),
    ).toContain('40%')
  })

  it('says so honestly when there is nothing to plot', () => {
    expect(text({ type: 'roadmap', snapshot: [] })).toContain('No roadmap items.')
    expect(text({ type: 'roadmap' })).toContain('No roadmap items.')
  })
})

/* ── 7. the fidelity catch-ups ─────────────────────────────────────────────── */

describe('the four fidelity catch-ups that rode this slice', () => {
  it('eyebrow renders the content[] shape (3 live papers rendered BLANK)', () => {
    const contentShape = { type: 'eyebrow', content: [{ type: 'text', value: 'FIELD NOTES' }] }
    expect(text(contentShape)).toBe('FIELD NOTES')
    // The bare-text path is byte-identical — the fallback only fires when
    // `content` is absent or empty.
    expect(text({ type: 'eyebrow', text: 'FIELD NOTES' })).toBe('FIELD NOTES')
    expect(text({ type: 'eyebrow', content: [], text: 'FALLBACK' })).toBe('FALLBACK')
    // Marks inside the inline array survive the trip.
    expect(
      text({ type: 'eyebrow', content: [{ type: 'text', value: 'bold', marks: [{ type: 'bold' }] }] }),
    ).toBe('bold')
  })

  it('cards paints tone — a danger card no longer renders identical to info', () => {
    const tint = (tone: string) =>
      walk({ type: 'cards', items: [{ title: 'T', text: 'b', tone }] }).styles[1]!.borderLeftColor
    expect(tint('info')).toBe(theme.accent)
    expect(tint('danger')).toBe(theme.danger)
    expect(tint('danger')).not.toBe(tint('info'))
    expect(tint('ok')).toBe(theme.success)
    expect(tint('warn')).toBe(theme.warn)
    // THREE distinct inks, not four — and that is a THEME fact, not a dropped
    // tone: both palettes define success as the same green as accent, so `info`
    // and `ok` legitimately collapse. The pair the live defect was about —
    // danger against info — is distinct, which is what this catch-up owed.
    expect(theme.success).toBe(theme.accent)
    expect(new Set(['info', 'ok', 'warn', 'danger'].map(tint)).size).toBe(3)
  })

  it('action opens its href through Linking — the dead label is gone', () => {
    const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true)
    try {
      const w = walk({ type: 'action', label: 'Open the board', href: 'https://example.com/board' })
      expect(w.text).toContain('Open the board')
      expect(w.presses).toHaveLength(1)
      w.presses[0]!()
      expect(open).toHaveBeenCalledWith('https://example.com/board')

      // An unsafe/relative href keeps the label VISIBLE but not tappable — never
      // a tap target that goes nowhere (the openableUrl gate, shared with inlines).
      for (const href of ['javascript:alert(1)', '/relative/path', '#anchor', '']) {
        const unsafe = walk({ type: 'action', label: 'Open', href })
        expect(unsafe.text).toContain('Open')
        expect(unsafe.presses).toHaveLength(0)
      }
      // An empty label still renders nothing, href or no href.
      expect(renderBlockNative({ type: 'action', label: '' }, paper, 0)).toBeNull()
      expect(renderBlockNative({ type: 'action', href: 'https://example.com' }, paper, 0)).toBeNull()
    } finally {
      open.mockRestore()
    }
  })

  it('ingress and pullquote stop painting serif under register: chat', () => {
    for (const type of ['ingress', 'pullquote']) {
      const block = { type, text: 'the lede' }
      // PAPER keeps its airy serif measures, byte-unchanged.
      expect(styleValues(walk(block, paper), 'fontFamily')).toEqual(['serif'])
      // CHAT takes the register's own body step and no face at all.
      expect(styleValues(walk(block, chat), 'fontFamily')).toEqual([])
      expect(walk(block, chat).styles[0]).toEqual(expect.objectContaining(roles.chatBody))
    }
    // The paper measures themselves did not move.
    expect(walk({ type: 'ingress', text: 'x' }, paper).styles[0]).toEqual(
      expect.objectContaining(roles.paperIngress),
    )
    expect(walk({ type: 'pullquote', text: 'x' }, paper).styles[0]).toEqual(
      expect.objectContaining(roles.paperPullquote),
    )
  })
})

/* ── 8. the register law, mechanically ─────────────────────────────────────── */

describe('the register law holds across the whole registry (D50)', () => {
  const BLOCKS_DIR = join(__dirname, '..', 'src', 'papers', 'portabledoc')

  it('NO registered renderer paints a serif face under register: chat', () => {
    // The strongest form of the law, and the one that would have caught the
    // ingress/pullquote leak: walk EVERY registered type in the chat register and
    // assert the serif face never appears. `roles.paperIngress` and
    // `roles.paperPullquote` carry fontFamily on the token, so an unconditional
    // reference to either from a chat-reachable path reds here.
    const probe: Record<string, unknown> = {
      text: 'prose',
      value: 'code',
      label: 'Label',
      title: 'Title',
      summary: 'Summary',
      caption: 'Caption',
      items: [{ text: 'one' }],
      blocks: [{ type: 'paragraph', text: 'nested' }],
      columns: [[{ type: 'paragraph', text: 'nested' }]],
      steps: [{ title: 'First', blocks: [{ type: 'paragraph', text: 'nested' }] }],
      slots: { body: [{ type: 'paragraph', text: 'nested' }] },
      nodes: [{ kind: 'k', title: 't' }],
      snapshot: [{ title: 'lane', status: 'done', left: 0, width: 50 }],
      task: { title: 'T', description: 'prose', criteria: [{ met: true, text: 'c' }] },
      notes: [{ text: 'a note' }],
      rows: [['a', 'b']],
      tabs: [{ label: 'One', blocks: [{ type: 'paragraph', text: 'nested' }] }],
      todos: [{ content: 'do it', status: 'pending' }],
      lines: ['+ added'],
      question: 'why?',
      options: [{ label: 'yes' }],
    }
    const offenders: string[] = []
    for (const type of Object.keys(BLOCK_RENDERERS)) {
      const faces = styleValues(walk({ ...probe, type }, chat), 'fontFamily')
      if (faces.includes('serif')) offenders.push(type)
    }
    expect(offenders).toEqual([])
    // The probe is not vacuous: the SAME sweep on the paper register does find
    // serif, so the assertion above is measuring something real.
    const paperFaces = Object.keys(BLOCK_RENDERERS).flatMap((type) =>
      styleValues(walk({ ...probe, type }, paper), 'fontFamily'),
    )
    expect(paperFaces).toContain('serif')
  })

  it('every recursion site forwards `ctx` WHOLESALE, never a re-minted literal', () => {
    // A re-minted `{ theme }` at a recursion site silently drops the register and
    // no rendered assertion above the recursion would notice, so this one is read
    // off the source: the second argument to renderBlockNative must be `ctx`.
    const files = [
      'blocks/core-container.tsx',
      'blocks/core-doc.tsx',
      'blocks/core-media.tsx',
      'registry.tsx',
    ]
    let sites = 0
    for (const rel of files) {
      const src = readFileSync(join(BLOCKS_DIR, rel), 'utf8')
      for (const m of src.matchAll(/renderBlockNative\(\s*([^)]*?)\)/gs)) {
        const args = m[1]!
        if (args.includes('block: unknown')) continue // the declaration itself
        sites++
        expect(`${rel}: ${args.replace(/\s+/g, ' ')}`).toMatch(/,\s*ctx\s*,/)
      }
    }
    // The scan resolved real call sites rather than matching nothing.
    expect(sites).toBeGreaterThanOrEqual(7)
  })

  it('the two serif tokens are referenced ONLY behind the paper-register branch', () => {
    const src = readFileSync(join(BLOCKS_DIR, 'blocks/core-prose.tsx'), 'utf8')
    for (const token of ['roles.paperIngress', 'roles.paperPullquote']) {
      expect(count(src, token)).toBe(1)
      const line = src.split('\n').find((l) => l.includes(token))!
      expect(line).toContain('isChat(ctx)')
    }
  })
})
