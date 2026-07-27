// The five core-code natives — tabs, code-tabs, api-endpoint, filetree, diff
// (mob-zb-s4-navcode-natives, charter D40/D46/D49/D50/D75-D78).
//
// This suite is SEMANTIC, not shape-descriptive: every assertion below is one a
// plausible future edit breaks silently.
//
//   1. THE SWITCH IS REAL. tabs/code-tabs are the only blocks on this surface
//      with state, so the strip is MOUNTED through react-test-renderer and the
//      press asserted — a host-free element walk cannot tell a working switch
//      from a strip of dead labels.
//   2. THE FOLD ASSERTS THE NUMBER. D40's `+N more lines` counts undisplayed
//      DRAWABLE rows; word-presence ("more lines") is blind to an off-by-one,
//      so every fold assertion pins the integer.
//   3. THE REGISTER REACHES THE PANES. tabs recurses through renderBlockNative
//      with ctx forwarded WHOLESALE (D50) — proven by the serif face appearing
//      on a nested paragraph in the paper register and NOT in the chat
//      register, which is exactly what a re-minted ctx literal would break.
//   4. ONE HORIZONTAL SCROLLER PER ROW (D50). Nested horizontal scrollers are
//      an Android removeClippedSubviews hazard, so the nesting DEPTH is
//      measured over all five types in both registers.
import type { ReactElement, ReactNode } from 'react'
import { ScrollView, Text } from 'react-native'
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'

import { coreCodeCases } from './cases/core-code.cases'
import { renderBlockNative, resetUnknownBlockLog, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { CHAT_DIFF_BUDGET } from '../src/papers/portabledoc/chat'
import {
  drawableCount,
  parseUnifiedDiffRows,
  splitFiletreeNote,
} from '../src/papers/portabledoc/blocks/core-code'
import { dark, light, type Theme } from '../src/ui/theme'

// The renderer graph reaches MermaidIsland (core-media) and therefore the
// WebView TurboModule; nothing here renders the island.
jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme: Theme = light
const paper: BlockCtx = { theme }
const chat: BlockCtx = { theme, register: 'chat' }

/* ── host-free element walking (the sibling suites' walker) ──────────────────── */

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

interface Walk {
  text: string
  styles: Record<string, unknown>[]
  /** The deepest nesting of `horizontal` scrollers seen on any path. */
  scrollDepth: number
}

function walkNode(node: ReactNode, acc: Walk, depth: number): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc, depth)
    return
  }
  if (isElement(node)) {
    const props = node.props as Record<string, unknown>
    const here = props.horizontal === true ? depth + 1 : depth
    if (here > acc.scrollDepth) acc.scrollDepth = here
    const raw = props.style
    if (raw !== undefined) {
      const parts = Array.isArray(raw) ? raw : [raw]
      acc.styles.push(Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>)
    }
    walkNode(props.children as ReactNode, acc, here)
  }
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', styles: [], scrollDepth: 0 }
  walkNode(node, acc, 0)
  return acc
}

function render(block: unknown, ctx: BlockCtx = paper): Walk {
  return walk(renderBlockNative(block, ctx, 0))
}

function textOf(block: unknown, ctx: BlockCtx = paper): string {
  return render(block, ctx).text
}

/* ── mounted rendering (the switch) ─────────────────────────────────────────── */

function mount(block: unknown, ctx: BlockCtx = paper): ReactTestRenderer {
  let tree!: ReactTestRenderer
  act(() => {
    tree = create(<>{renderBlockNative(block, ctx, 0)}</>)
  })
  return tree
}

/** Every string in the MOUNTED (host) tree — what the reader actually sees,
 * i.e. the active pane only. */
function mountedText(tree: ReactTestRenderer): string {
  const seen: string[] = []
  const visit = (node: unknown): void => {
    if (typeof node === 'string') {
      seen.push(node)
      return
    }
    if (Array.isArray(node)) {
      node.forEach(visit)
      return
    }
    if (node && typeof node === 'object' && 'children' in (node as object)) {
      visit((node as { children: unknown }).children)
    }
  }
  visit(tree.toJSON())
  return seen.join(' ')
}

/** The tab strip's press targets. `findAllByType(Pressable)` matches nothing
 * (RN's Pressable is a forwardRef/memo wrapper) and matching the role alone
 * returns the host Views it renders into as well, so the handler IS the
 * identity: one instance per tab, in strip order. */
function tabButtons(tree: ReactTestRenderer): ReactTestInstance[] {
  return tree.root.findAll(
    (n) => n.props.accessibilityRole === 'tab' && typeof n.props.onPress === 'function',
  )
}

/** Press the i-th tab. Throws rather than silently no-op'ing on a missing
 * index — a strip that lost a tab must red here, not pass quietly. */
function pressTab(tree: ReactTestRenderer, i: number): void {
  const button = tabButtons(tree)[i]
  if (button === undefined) throw new Error(`no tab at strip index ${i}`)
  act(() => (button.props as { onPress: () => void }).onPress())
}

/* ── 1. tabs ────────────────────────────────────────────────────────────────── */

const TABS = {
  type: 'tabs',
  tabs: [
    { label: 'Install', blocks: [{ type: 'paragraph', text: 'PANE_ONE_BODY' }] },
    { label: 'Use', blocks: [{ type: 'paragraph', text: 'PANE_TWO_BODY' }] },
    { blocks: [{ type: 'paragraph', text: 'PANE_THREE_BODY' }] },
  ],
}

describe('tabs — a real switch, mounted', () => {
  it('shows the FIRST pane and only the first pane on mount', () => {
    const tree = mount(TABS)
    try {
      const out = mountedText(tree)
      expect(out).toContain('PANE_ONE_BODY')
      expect(out).not.toContain('PANE_TWO_BODY')
      // Every label is reachable in the strip, blank label → the `·` placeholder
      // (tabs.go tabEntries) so no tab is unlabeled and untappable.
      expect(out).toContain('Install')
      expect(out).toContain('Use')
      expect(out).toContain('·')
    } finally {
      act(() => tree.unmount())
    }
  })

  it('PRESSING a tab switches the pane — the state is not decoration', () => {
    const tree = mount(TABS)
    try {
      expect(tabButtons(tree)).toHaveLength(3)
      pressTab(tree, 1)
      let out = mountedText(tree)
      expect(out).toContain('PANE_TWO_BODY')
      expect(out).not.toContain('PANE_ONE_BODY')
      // MUTANT: drop the setActive call (or hard-code index 0) and this flips
      // while the host-free case row stays green — the walk sees every pane.
      pressTab(tree, 2)
      out = mountedText(tree)
      expect(out).toContain('PANE_THREE_BODY')
      expect(out).not.toContain('PANE_TWO_BODY')
      pressTab(tree, 0)
      expect(mountedText(tree)).toContain('PANE_ONE_BODY')
    } finally {
      act(() => tree.unmount())
    }
  })

  it('marks the active tab selected for a screen reader, and moves the mark', () => {
    const tree = mount(TABS)
    try {
      const selected = (): boolean[] =>
        tabButtons(tree).map((b) => (b.props.accessibilityState as { selected: boolean }).selected)
      expect(selected()).toEqual([true, false, false])
      pressTab(tree, 2)
      expect(selected()).toEqual([false, false, true])
    } finally {
      act(() => tree.unmount())
    }
  })

  it('gives every tab a 44pt tap target — a 29pt strip is the web geometry, not a phone one', () => {
    const tree = mount(TABS)
    try {
      for (const b of tabButtons(tree)) {
        expect((b.props.style as { minHeight: number }).minHeight).toBe(44)
      }
    } finally {
      act(() => tree.unmount())
    }
  })

  it('is HOOK-FREE at the Render boundary — panes ride as children (the no-JS degrade)', () => {
    // The Render function itself must stay pure: a host-free walk of what it
    // returns sees EVERY pane, exactly like the reference's pre-hydration
    // markup. This is what keeps the shared case-row walker (and the crown
    // slice's cross-surface floor) from reading a tabs block as empty.
    const out = textOf(TABS)
    expect(out).toContain('PANE_ONE_BODY')
    expect(out).toContain('PANE_TWO_BODY')
    expect(out).toContain('PANE_THREE_BODY')
  })

  it('forwards ctx WHOLESALE — the register reaches the nested pane blocks (D50)', () => {
    // The pane's paragraph goes through the shared dispatcher, so it must speak
    // the OUTER register: serif in the paper reader, the system sans in chat. A
    // re-minted `{ theme }` literal would silently paint chat panes serif.
    const serif = (ctx: BlockCtx): number =>
      render(TABS, ctx).styles.filter((s) => s.fontFamily === 'serif').length
    expect(serif(paper)).toBeGreaterThan(0)
    expect(serif(chat)).toBe(0)
  })

  it('renders nothing for an empty or malformed tabs list — the honest empty state', () => {
    for (const block of [
      { type: 'tabs' },
      { type: 'tabs', tabs: [] },
      { type: 'tabs', tabs: 'nope' },
      { type: 'tabs', tabs: ['string', 7] },
    ]) {
      expect(renderBlockNative(block, paper, 0)).toBeNull()
    }
  })
})

/* ── 2. code-tabs ───────────────────────────────────────────────────────────── */

const CODE_TABS = {
  type: 'code-tabs',
  syncKey: 'lang',
  tabs: [
    { label: 'curl', language: 'bash', value: 'curl /v1/capabilities' },
    { language: 'javascript', value: 'await bp.capabilities()' },
    { code: 'print(1)' },
  ],
}

describe('code-tabs — language-labeled code panes', () => {
  it('labels the strip, falling back to the LANGUAGE then to the placeholder', () => {
    const tree = mount(CODE_TABS)
    try {
      const labels = tabButtons(tree).map((b) => b.props.accessibilityLabel)
      expect(labels).toEqual(['curl', 'javascript', '·'])
    } finally {
      act(() => tree.unmount())
    }
  })

  it('paints the active pane WITH its language label above the snippet', () => {
    const tree = mount(CODE_TABS)
    try {
      let out = mountedText(tree)
      expect(out).toContain('bash')
      expect(out).toContain('curl /v1/capabilities')
      expect(out).not.toContain('await bp.capabilities()')
      pressTab(tree, 1)
      out = mountedText(tree)
      expect(out).toContain('javascript')
      expect(out).toContain('await bp.capabilities()')
      expect(out).not.toContain('curl /v1/capabilities')
    } finally {
      act(() => tree.unmount())
    }
  })

  it('reads `code` when `value` is absent', () => {
    const tree = mount(CODE_TABS)
    try {
      pressTab(tree, 2)
      const out = mountedText(tree)
      expect(out).toContain('print(1)')
    } finally {
      act(() => tree.unmount())
    }
  })

  it('omits the language label row entirely for a language-less pane', () => {
    // The label row is the ONLY uppercased run this family writes, so its
    // presence is decidable from the styles: an unauthored language must not
    // leave an empty uppercase strip above the snippet.
    const labelRows = (tab: Record<string, unknown>): number =>
      render({ type: 'code-tabs', tabs: [tab] }).styles.filter(
        (s) => s.textTransform === 'uppercase',
      ).length
    expect(labelRows({ language: 'python', value: 'print(1)' })).toBe(1)
    expect(labelRows({ value: 'print(1)' })).toBe(0)
  })

  it('renders the pane THROUGH the registered `code` renderer, not a second slab', () => {
    // The code fence has exactly ONE owner (core-media). The proof: the pane
    // carries the code renderer's paper-register chrome — the accent rule and
    // the surface slab — which this family never writes itself.
    const styles = render(CODE_TABS, paper).styles
    expect(styles.some((s) => s.borderLeftWidth === 3 && s.borderLeftColor === theme.accent)).toBe(
      true,
    )
    // …and in the chat register it carries the codeBg region instead, which is
    // the same renderer reading ctx.register. A hand-rolled slab here would
    // paint one of the two and never both.
    expect(render(CODE_TABS, chat).styles.some((s) => s.backgroundColor === theme.codeBg)).toBe(true)
  })

  it('renders nothing for an empty tabs list', () => {
    expect(renderBlockNative({ type: 'code-tabs', tabs: [] }, paper, 0)).toBeNull()
    expect(renderBlockNative({ type: 'code-tabs' }, chat, 0)).toBeNull()
  })
})

/* ── 3. api-endpoint ────────────────────────────────────────────────────────── */

describe('api-endpoint — method + path + params', () => {
  const block = {
    type: 'api-endpoint',
    method: 'post',
    path: '/v1/data/mutate',
    params: [
      { name: 'dataset', in: 'path', type: 'string', required: true },
      { name: 'dryRun', in: 'query', type: 'boolean' },
      { name: 'strict', in: 'query', type: 'boolean', required: 'TRUE' },
    ],
  }

  it('paints the UPPERCASED method, the path, and every param row', () => {
    const out = textOf(block)
    expect(out).toContain('POST')
    expect(out).toContain('/v1/data/mutate')
    expect(out).toContain('dataset')
    expect(out).toContain('path · string · required')
    expect(out).toContain('dryRun')
    // "Required: No" is information, so the optional case is SPELLED OUT rather
    // than being the absence of a word.
    expect(out).toContain('query · boolean · optional')
    // The string "TRUE" is truthy for `required` on every other surface too.
    expect(out).toContain('strict')
    expect(out.match(/required/g)).toHaveLength(2)
  })

  it('tones the method badge by VERB, off the status palette', () => {
    const badge = (method: string, t: Theme = light): unknown => {
      const styles = render({ type: 'api-endpoint', method, path: '/x' }, { theme: t }).styles
      return styles.find((s) => s.borderRadius === 6 && s.borderWidth === 1)?.color
    }
    expect(badge('get')).toBe(light.success)
    expect(badge('post')).toBe(light.accent)
    expect(badge('put')).toBe(light.warn)
    expect(badge('patch')).toBe(light.warn)
    expect(badge('delete')).toBe(light.danger)
    // An unrecognized verb stays MUTED rather than borrowing a meaning.
    expect(badge('teleport')).toBe(light.textMuted)
    // The tones are theme tokens, not hexes: the dark theme moves them.
    expect(badge('get', dark)).toBe(dark.success)
  })

  it('renders a path-only or method-only block, and nothing at all for neither', () => {
    expect(textOf({ type: 'api-endpoint', path: '/v1/ping' })).toContain('/v1/ping')
    expect(textOf({ type: 'api-endpoint', method: 'head' })).toContain('HEAD')
    expect(renderBlockNative({ type: 'api-endpoint' }, paper, 0)).toBeNull()
    expect(renderBlockNative({ type: 'api-endpoint', method: '', path: '' }, chat, 0)).toBeNull()
  })

  it('skips non-object param entries instead of crashing the card', () => {
    const out = textOf({
      type: 'api-endpoint',
      method: 'get',
      path: '/x',
      params: ['nope', 7, { name: 'real' }],
    })
    expect(out).toContain('real')
    expect(out).not.toContain('Unsupported block')
  })
})

/* ── 4. filetree ────────────────────────────────────────────────────────────── */

describe('filetree — verbatim tree lines + annotation tones (D78)', () => {
  const tree = {
    type: 'filetree',
    text:
      'api/render/\n' +
      '├── components.ex ● diff_html/1\n' +
      '├── compose.ex ○ grew the clauses\n' +
      '└── starter_stub.ex ✕ removed',
    legend: '● created · ○ injected · ✕ removed',
  }

  it('keeps the box glyphs and the indentation VERBATIM', () => {
    const out = textOf(tree)
    expect(out).toContain('├── components.ex')
    expect(out).toContain('└── starter_stub.ex')
    expect(out).toContain('api/render/')
  })

  it('splits on the EARLIEST marker and tones the note run, path left alone', () => {
    const s = splitFiletreeNote('lib/a.ex ● made ○ then injected', light)
    expect(s).not.toBeNull()
    expect(s!.path).toBe('lib/a.ex')
    expect(s!.note).toBe(' ● made ○ then injected')
    expect(s!.color).toBe(light.success)
    // The glyph stays IN the note — it is the semantic carrier, the tone is not.
    expect(s!.note.startsWith(' ● ')).toBe(true)
    expect(splitFiletreeNote('lib/a.ex', light)).toBeNull()
  })

  it('gives each of the three markers its canonical tone (● ok · ○ dim · ✕ danger)', () => {
    for (const [line, color] of [
      ['a ● new', light.success],
      ['a ○ touched', light.textMuted],
      ['a ✕ gone', light.danger],
    ] as [string, string][]) {
      expect(splitFiletreeNote(line, light)!.color).toBe(color)
    }
    const styles = render(tree).styles
    for (const color of [light.success, light.textMuted, light.danger]) {
      expect(styles.some((s) => s.color === color)).toBe(true)
    }
  })

  it('renders the legend row, and omits it when unauthored', () => {
    expect(textOf(tree)).toContain('● created · ○ injected · ✕ removed')
    expect(textOf({ type: 'filetree', text: 'a\nb' })).toBe('ab')
  })

  it('renders nothing for empty or whitespace-only text — never a blank row', () => {
    for (const text of [undefined, '', '   ', '\n\n']) {
      expect(renderBlockNative({ type: 'filetree', text }, paper, 0)).toBeNull()
    }
  })
})

/* ── 5. diff ────────────────────────────────────────────────────────────────── */

const UNIFIED =
  'diff --git a/lib/compose.ex b/lib/compose.ex\n' +
  'index 3f9c2d1..8a41b7e 100644\n' +
  '--- a/lib/compose.ex\n' +
  '+++ b/lib/compose.ex\n' +
  '@@ -1,4 +1,5 @@\n' +
  ' defmodule Compose do\n' +
  '-  def old, do: :todo\n' +
  '+  def new, do: :done\n' +
  '+  def also, do: :done\n' +
  ' end'

describe('diff — the verbatim unified-diff front-end (D75-D77)', () => {
  it('folds the git metadata away and never counts it as a row', () => {
    const rows = parseUnifiedDiffRows(UNIFIED)
    expect(rows.map((r) => r.op)).toEqual(['file', '@', ' ', '-', '+', '+', ' '])
    // MUTANT: drop the `index `/`diff --git` arm and two junk rows appear here.
    expect(rows.some((r) => r.text.startsWith('index '))).toBe(false)
    expect(rows.some((r) => r.text.startsWith('diff --git'))).toBe(false)
  })

  it('keeps the `@@` hunk header VERBATIM — the line numbers are PR context', () => {
    const rows = parseUnifiedDiffRows(UNIFIED)
    expect(rows.find((r) => r.op === '@')!.text).toBe('@@ -1,4 +1,5 @@')
  })

  it('mints ONE bold path sub-header per `+++` transition, `a/`/`b/` stripped', () => {
    const rows = parseUnifiedDiffRows(
      '--- a/one.ex\n+++ b/one.ex\n+x\n--- a/two.ex\n+++ b/two.ex\n+y',
    )
    expect(rows.filter((r) => r.op === 'file').map((r) => r.text)).toEqual(['one.ex', 'two.ex'])
  })

  it('remembers the `--- ` path so a deletion to /dev/null still gets a header', () => {
    // react's core.ts diffLineRow drops `--- ` on the floor and would emit NO
    // header here — the file being deleted would go unnamed.
    const rows = parseUnifiedDiffRows('--- a/gone.ex\n+++ /dev/null\n-x')
    expect(rows[0]).toEqual({ op: 'file', text: 'gone.ex' })
  })

  it('strips the context gutter but never drops or invents a body line', () => {
    const rows = parseUnifiedDiffRows(' kept\nunprefixed')
    expect(rows).toEqual([
      { op: ' ', text: 'kept' },
      { op: ' ', text: 'unprefixed' },
    ])
  })

  it('paints the file/lang lead and the +N −M tally', () => {
    const out = textOf({ type: 'diff', file: 'lib/compose.ex', lang: 'elixir', diff: UNIFIED })
    expect(out).toContain('lib/compose.ex')
    expect(out).toContain('elixir')
    expect(out).toContain('+2')
    expect(out).toContain('−1')
  })

  it('colors + rows on the ok tone and − rows on danger, in both registers', () => {
    for (const ctx of [paper, chat]) {
      const styles = render({ type: 'diff', diff: UNIFIED }, ctx).styles
      expect(styles.some((s) => s.color === light.success && s.backgroundColor === light.successSoft)).toBe(
        true,
      )
      expect(styles.some((s) => s.color === light.danger && s.backgroundColor === light.dangerSoft)).toBe(
        true,
      )
    }
  })

  it('reads the starter-era `text` key when `diff` is absent', () => {
    expect(textOf({ type: 'diff', text: '+hello' })).toContain('hello')
  })

  it('renders nothing for an empty diff — the honest empty state', () => {
    for (const b of [{ type: 'diff' }, { type: 'diff', diff: '' }, { type: 'diff', diff: '  \n' }]) {
      expect(renderBlockNative(b, paper, 0)).toBeNull()
    }
  })
})

describe('diff — the D40 fold: drawable-only, 20-line budget, the NUMBER', () => {
  /** A diff with `n` added rows and nothing else drawable. */
  function longDiff(n: number): string {
    return Array.from({ length: n }, (_, i) => `+line ${i}`).join('\n')
  }

  it('is the SHARED budget constant — never a second 20', () => {
    expect(CHAT_DIFF_BUDGET).toBe(20)
  })

  it('draws exactly the budget and footnotes the exact overflow COUNT', () => {
    const rows = parseUnifiedDiffRows(longDiff(25))
    expect(drawableCount(rows)).toBe(25)
    const out = textOf({ type: 'diff', diff: longDiff(25) })
    // The literal number, not the word: "… +5 more lines". An off-by-one here
    // is invisible to a `toContain('more lines')`.
    expect(out).toContain('… +5 more lines')
    expect(out).not.toContain('… +4 more lines')
    expect(out).not.toContain('… +6 more lines')
    // …and only the first 20 rows are DRAWN (row 19 in, row 20 out).
    expect(out).toContain('line 19')
    expect(out).not.toContain('line 20')
    // The tally is over ALL rows, folded or not — a fold never lies about size.
    expect(out).toContain('+25')
  })

  it('does not fold at exactly the budget, and folds by one at budget+1', () => {
    const at = textOf({ type: 'diff', diff: longDiff(CHAT_DIFF_BUDGET) })
    expect(at).not.toContain('more lines')
    expect(at).toContain('line 19')
    const over = textOf({ type: 'diff', diff: longDiff(CHAT_DIFF_BUDGET + 1) })
    expect(over).toContain('… +1 more lines')
  })

  it('spends budget on the `+++` path sub-header like any other drawn row', () => {
    // 20 adds preceded by a file header = 21 drawable rows, so the header
    // displaces the last add and the footnote reads +1.
    const out = textOf({
      type: 'diff',
      diff: '--- a/f.ex\n+++ b/f.ex\n' + longDiff(20),
    })
    expect(out).toContain('f.ex')
    expect(out).toContain('… +1 more lines')
    expect(out).not.toContain('line 19')
  })

  it('counts DRAWABLE rows only — a gap row is a rule, not a line of code', () => {
    // parseUnifiedDiffRows emits no `gap` rows (D40's confined-divergence
    // clause), so this pins the denominator directly on the exported helper:
    // the law must survive a parser that later learns to collapse hunks.
    const rows = [
      ...Array.from({ length: 22 }, () => ({ op: '+', text: 'x' })),
      { op: 'gap', text: '' },
    ]
    expect(drawableCount(rows)).toBe(22)
    expect(drawableCount(rows) - CHAT_DIFF_BUDGET).toBe(2)
  })
})

/* ── 6. the family-wide laws ────────────────────────────────────────────────── */

describe('the whole core-code family', () => {
  const registers: [string, BlockCtx][] = [
    ['paper', paper],
    ['chat', chat],
  ]

  it('never nests a horizontal scroller inside another (D50, Android clipping)', () => {
    const depths = coreCodeCases.flatMap(({ type, block }) =>
      registers.map(([name, ctx]) => `${type}/${name}=${render(block, ctx).scrollDepth}`),
    )
    expect(depths.filter((d) => !/=[01]$/.test(d))).toEqual([])
    // NON-VACUITY, both directions: some case must actually OPEN a scroller
    // (otherwise the walker is measuring nothing), and the walker must be able
    // to SEE a nested pair (otherwise the pin above can never red).
    expect(depths).toContain('diff/paper=1')
    const nested = walk(
      <ScrollView horizontal>
        <ScrollView horizontal>
          <Text>x</Text>
        </ScrollView>
      </ScrollView>,
    )
    expect(nested.scrollDepth).toBe(2)
  })

  it('renders every authored case in BOTH registers without the unknown fallback', () => {
    // The shared registry tripwire only walks the chat register; the paper
    // reader is the other half of the wish.
    for (const { type, block } of coreCodeCases) {
      for (const [name, ctx] of registers) {
        const out = render(block, ctx).text
        expect(`${type}/${name}: ${out}`).not.toContain('Unsupported block')
        expect(out.length).toBeGreaterThan(0)
      }
    }
  })

  it('never paints the SERIF face itself — the chat register stays sans (D50)', () => {
    // The measured D50 leak was a renderer hard-coding the paper face. Nothing
    // in this band writes a face other than MONO; the only serif that may
    // appear is a nested prose block reached through the dispatcher in the
    // PAPER register (the tabs pane), which is exactly the wholesale-ctx proof.
    for (const { type, block } of coreCodeCases) {
      const serif = render(block, chat).styles.filter((s) => s.fontFamily === 'serif')
      expect(`${type}: ${serif.length}`).toBe(`${type}: 0`)
    }
  })

  it('registers all five types — an attr-less block degrades to null, not to the unknown box', () => {
    resetUnknownBlockLog()
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      for (const type of ['tabs', 'code-tabs', 'api-endpoint', 'filetree', 'diff']) {
        expect(`${type}: ${renderBlockNative({ type }, paper, 0)}`).toBe(`${type}: null`)
      }
      // The unknown path logs; the honest empty state must not.
      expect(warn).not.toHaveBeenCalled()
    } finally {
      warn.mockRestore()
    }
  })
})
