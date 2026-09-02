// The two T1 GRID natives (mob-zb-s6-grid-natives, charter D46 b/c):
//
//   • sheet      — an ALIGNED horizontal-scroll grid. The law this suite exists
//                  for is the one the sibling table renderer breaks: the same
//                  width at column index i in EVERY row. A per-cell
//                  minWidth/maxWidth passes every "it renders" assertion and
//                  still misaligns the grid, so the widths are read out of the
//                  tree per row and compared, not eyeballed.
//   • task-board — SEVEN role lanes in ladder order, and the harder invariant:
//                  a row is NEVER dropped. The TUI resolves considering/
//                  researching and then silently drops those rows; Elixir drops
//                  cancelled ones. Mobile follows react, so the proof is a
//                  card count equal to the INPUT length, including a laneless
//                  role and a row that is not even a map.
//
// Like the sibling suites this walks the element trees the PURE renderers
// return — no native host, no react-test-renderer.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import type { ReactElement, ReactNode } from 'react'

import { renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { light, type Theme } from '../src/ui/theme'

// react-native-webview is a native TurboModule with no jest mock of its own and
// the block barrel reaches MermaidIsland. jest hoists this above the imports.
jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme: Theme = light
const paper: BlockCtx = { theme }
const chat: BlockCtx = { theme, register: 'chat' }

const REPO = join(__dirname, '..', '..', '..')

/** The engine error vocabulary, read from the fixture
 * `api/test/barkpark/sheets_parity_test.exs` holds equal to
 * `Barkpark.Plugins.Sheets.Engine.error_values/0` — the same file the web and
 * react mirrors consume. See `sheetErrorVocabulary.test.ts` for the drift
 * guard that pins the renderer's own set to it. */
const ENGINE_ERRORS: string[] = JSON.parse(
  readFileSync(join(REPO, 'web', '__tests__', 'fixtures', 'engine-errors.json'), 'utf8'),
)

/* ── element-tree helpers ───────────────────────────────────────────────────── */

type Props = Record<string, unknown>

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function props(el: ReactElement): Props {
  return el.props as Props
}

/** A style prop is an object or an array of them; flatten to one object. */
function flatStyle(style: unknown): Props {
  if (Array.isArray(style)) {
    const out: Props = {}
    for (const s of style) Object.assign(out, flatStyle(s))
    return out
  }
  return style !== null && typeof style === 'object' ? (style as Props) : {}
}

function kids(node: unknown): ReactNode[] {
  if (Array.isArray(node)) return node.flatMap((n) => kids(n))
  if (node === null || node === undefined || typeof node === 'boolean') return []
  return [node as ReactNode]
}

function visit(node: ReactNode, fn: (el: ReactElement) => void): void {
  for (const child of kids(node)) {
    if (!isElement(child)) continue
    fn(child)
    visit(props(child).children as ReactNode, fn)
  }
}

function allText(node: ReactNode): string {
  let out = ''
  for (const child of kids(node)) {
    if (typeof child === 'string') out += child
    else if (typeof child === 'number') out += String(child)
    else if (isElement(child)) out += allText(props(child).children as ReactNode)
  }
  return out
}

function firstText(node: ReactNode): string {
  for (const child of kids(node)) {
    if (typeof child === 'string' && child !== '') return child
    if (isElement(child)) {
      const inner = firstText(props(child).children as ReactNode)
      if (inner !== '') return inner
    }
  }
  return ''
}

function render(block: unknown, ctx: BlockCtx = paper): ReactNode {
  return renderBlockNative(block, ctx, 0)
}

function fontFamilies(node: ReactNode): string[] {
  const out: string[] = []
  visit(node, (el) => {
    const face = flatStyle(props(el).style).fontFamily
    if (typeof face === 'string') out.push(face)
  })
  return out
}

/** Every element's flattened style, in tree order — the shape a register change
 * would move. */
function styleCensus(node: ReactNode): string[] {
  const out: string[] = []
  visit(node, (el) => out.push(JSON.stringify(flatStyle(props(el).style))))
  return out
}

/* ── grid readers ───────────────────────────────────────────────────────────── */

interface Cell {
  value: string
  width: number
  bg?: string
  align?: unknown
  color?: unknown
  weight?: unknown
  fontStyle?: unknown
  underline?: unknown
  face?: unknown
  pressable: boolean
}

/** Every sheet cell, in tree order (head row first, then body row-major). A
 * cell is the one element in this renderer that carries a numeric `width`. */
function cellsIn(node: ReactNode): Cell[] {
  const out: Cell[] = []
  visit(node, (el) => {
    const box = flatStyle(props(el).style)
    if (typeof box.width !== 'number') return
    const inner = kids(props(el).children).filter(isElement)[0]
    if (inner === undefined) return
    const ip = props(inner)
    const ts = flatStyle(ip.style)
    out.push({
      value: allText(ip.children as ReactNode),
      width: box.width,
      bg: typeof box.backgroundColor === 'string' ? box.backgroundColor : undefined,
      align: ts.textAlign,
      color: ts.color,
      weight: ts.fontWeight,
      fontStyle: ts.fontStyle,
      underline: ts.textDecorationLine,
      face: ts.fontFamily,
      pressable: typeof ip.onPress === 'function',
    })
  })
  return out
}

/** The per-row width tuples — a row whose element children ALL carry a numeric
 * width. This is the alignment law's measuring instrument. */
function gridRows(node: ReactNode): number[][] {
  const out: number[][] = []
  visit(node, (el) => {
    if (flatStyle(props(el).style).flexDirection !== 'row') return
    const widths = kids(props(el).children)
      .filter(isElement)
      .map((k) => flatStyle(props(k).style).width)
    if (widths.length > 0 && widths.every((w) => typeof w === 'number')) out.push(widths as number[])
  })
  return out
}

function sheetOf(snapshot: unknown): Record<string, unknown> {
  return { type: 'sheet', snapshot }
}

/** A sheet with N unnamed head columns — the fixture for the width gates, where
 * only the geometry is under test. */
function widthsFor(colWidths: unknown[]): number[] {
  const head = colWidths.map(() => '')
  const rows = gridRows(render(sheetOf({ head, rows: [], col_widths: colWidths })))
  return rows[0] ?? []
}

/* ── board readers ──────────────────────────────────────────────────────────── */

interface Lane {
  label: string
  count: string
  text: string
}

/** Every lane, in render order. A lane is the element carrying the 3pt
 * role-coloured top rule; its count is the pill (borderRadius 999). */
function lanesIn(node: ReactNode): Lane[] {
  const out: Lane[] = []
  visit(node, (el) => {
    const s = flatStyle(props(el).style)
    if (s.borderTopWidth !== 3) return
    let count = ''
    visit(props(el).children as ReactNode, (inner) => {
      if (flatStyle(props(inner).style).borderRadius === 999) count = allText(props(inner).children as ReactNode)
    })
    out.push({
      label: firstText(props(el).children as ReactNode),
      count,
      text: allText(props(el).children as ReactNode),
    })
  })
  return out
}

/** Every board card (borderRadius 7) — the count that must equal the input row
 * count for "a row is never dropped" to mean anything. */
function cardCount(node: ReactNode): number {
  let n = 0
  visit(node, (el) => {
    if (flatStyle(props(el).style).borderRadius === 7) n += 1
  })
  return n
}

function boardOf(snapshot: unknown): Record<string, unknown> {
  return { type: 'task-board', snapshot }
}

/* ══ sheet ══════════════════════════════════════════════════════════════════ */

describe('sheet — the alignment law (D46b)', () => {
  const SHEET = sheetOf({
    head: ['Item', 'Qty', 'Note'],
    rows: [
      ['Widget', '1,200', 'https://example.com/a'],
      ['Gadget', '3.5%', ''],
      ['#REF!', 'TRUE', '2026-07-26'],
    ],
    col_widths: [80, 200],
  })

  it('gives column index i the SAME width in EVERY row', () => {
    const rows = gridRows(render(SHEET))
    // head + 3 body rows
    expect(rows).toHaveLength(4)
    for (const widths of rows) expect(widths).toEqual([80, 200, 120])
    // The instrument can fail: a renderer that emitted no fixed widths at all
    // would return [] here and every toEqual above would be skipped.
    expect(rows.length).toBeGreaterThan(0)
  })

  it('honors col_widths as pt hints, defaults the rest to 120, clamps the absurd', () => {
    // integer > 0 verbatim · string · negative · zero · fractional · unbounded · tiny
    expect(widthsFor([80, '200', -5, 0, 1.5, 1_000_000_000, 4])).toEqual([
      80, 120, 120, 120, 120, 600, 32,
    ])
    // absent col_widths entirely → every column takes the default measure
    expect(gridRows(render(sheetOf({ head: ['a', 'b'], rows: [] })))[0]).toEqual([120, 120])
  })

  it('pads a ragged snapshot to a rectangle rather than letting the grid wander', () => {
    const out = render(sheetOf({ rows: [['a', 'b', 'c'], ['d']] }))
    expect(gridRows(out)).toEqual([
      [120, 120, 120],
      [120, 120, 120],
    ])
    expect(cellsIn(out).map((c) => c.value)).toEqual(['a', 'b', 'c', 'd', '', ''])
  })

  it('does NOT copy the table renderer per-cell min/max shape', () => {
    // The latent table defect D46b names: rows lay out independently there.
    for (const cell of cellsIn(render(SHEET))) {
      expect(cell.width).toBeGreaterThan(0)
    }
    const tableRows = gridRows(render({ type: 'table', head: ['a', 'b'], rows: [['1', '2']] }))
    // The table renderer sets minWidth/maxWidth and NO width, so it produces no
    // fixed-width rows at all — proof the two shapes are genuinely different.
    expect(tableRows).toEqual([])
  })
})

describe('sheet — the TUI floor: head / rows / truncated', () => {
  it('uppercases the head labels (.bp-sheet__th treatment)', () => {
    expect(cellsIn(render(sheetOf({ head: ['Item'], rows: [['x']] }))).map((c) => c.value)).toEqual([
      'ITEM',
      'x',
    ])
  })

  it('renders a head-less sheet as a bare grid', () => {
    expect(cellsIn(render(sheetOf({ rows: [['x', 'y']] }))).map((c) => c.value)).toEqual(['x', 'y'])
  })

  it('the truncation note is byte-matched to the react AND Go sources, counting the rows SHOWN', () => {
    // A copied literal proves nothing, so the other two surfaces' own source is
    // the oracle: extract their format string and substitute the count.
    const NOTE_RE = /Sheet truncated — showing the first (\$\{[^}]*\}|%d) rows/
    const reactSrc = readFileSync(join(REPO, 'js/packages/react/src/blocks/sheet.ts'), 'utf8')
    const goSrc = readFileSync(join(REPO, 'internal/pdrender/sheet.go'), 'utf8')
    const reactNote = NOTE_RE.exec(reactSrc)
    const goNote = NOTE_RE.exec(goSrc)
    expect(reactNote).not.toBeNull()
    expect(goNote).not.toBeNull()

    const out = allText(render(sheetOf({ rows: [['a'], ['b']], truncated: true })))
    expect(out).toContain(reactNote![0].replace(/\$\{[^}]*\}/, '2'))
    expect(out).toContain(goNote![0].replace('%d', '2'))
    expect(out).toContain('Sheet truncated — showing the first 2 rows')
  })

  it('says nothing when the snapshot is complete', () => {
    expect(allText(render(sheetOf({ rows: [['a']] })))).not.toContain('truncated')
    expect(allText(render(sheetOf({ rows: [['a']], truncated: 'yes' })))).not.toContain('truncated')
  })
})

describe('sheet — per-cell styles, engine errors, alignment, URLs', () => {
  it('honors b / i / bg / al', () => {
    const cells = cellsIn(
      render(
        sheetOf({
          rows: [['w', 'x', 'y', 'z']],
          styles: { '0,0': { b: true }, '0,1': { i: true }, '0,2': { bg: '#ff0000' }, '0,3': { al: 'right' } },
        }),
      ),
    )
    expect(cells[0]?.weight).toBe('700')
    expect(cells[1]?.fontStyle).toBe('italic')
    expect(cells[2]?.bg).toBe('#ff0000')
    expect(cells[3]?.align).toBe('right')
    // and the unstyled neighbours stay clean
    expect(cells[0]?.fontStyle).toBeUndefined()
    expect(cells[1]?.weight).toBeUndefined()
  })

  it('drops a bg that is not a strict #rrggbb (the CondFormat valid_bg? gate)', () => {
    const cells = cellsIn(
      render(sheetOf({ rows: [['a', 'b', 'c']], styles: { '0,0': { bg: 'red' }, '0,1': { bg: '#FFF' }, '0,2': { bg: '#AbCdEf' } } })),
    )
    expect(cells[0]?.bg).toBeUndefined()
    expect(cells[1]?.bg).toBeUndefined()
    expect(cells[2]?.bg).toBe('#AbCdEf')
  })

  it('paints EVERY engine-error value red + bold, and nothing else', () => {
    // The list is read from the engine-generated fixture, NOT hand-written
    // here. A hand-written copy was the defect this test used to carry: it
    // named seven codes and went stale the moment #15374 added `#NAME?`
    // engine-side, so the suite stayed green over a value mobile painted as
    // plain text. Reading ENGINE_ERRORS means a code added engine-side is
    // exercised through the real renderer the same day it lands.
    const errors = ENGINE_ERRORS
    expect(errors.length).toBeGreaterThanOrEqual(8)
    const cells = cellsIn(render(sheetOf({ rows: [[...errors, '#OTHER!', 'REF!']] })))
    expect(cells).toHaveLength(errors.length + 2)
    for (const [i] of errors.entries()) {
      expect(`${errors[i]}: ${String(cells[i]?.color)}`).toBe(`${errors[i]}: ${theme.danger}`)
      expect(cells[i]?.weight).toBe('700')
    }
    expect(cells[errors.length]?.color).toBe(theme.text)
    expect(cells[errors.length]?.weight).toBeUndefined()
    expect(cells[errors.length + 1]?.color).toBe(theme.text)
  })

  it('right-aligns numeric + temporal, centres booleans, leaves prose alone', () => {
    const values = ['1,200', '42', '-$1,234.56', '3.5%', '1e5', '2026-07-26', '2026-07-26 10:00:00', 'TRUE', 'FALSE', 'Widget', '']
    const cells = cellsIn(render(sheetOf({ rows: [values] })))
    expect(cells.map((c) => c.align)).toEqual([
      'right',
      'right',
      'right',
      'right',
      'right',
      'right',
      'right',
      'center',
      'center',
      'left',
      'left',
    ])
  })

  it('an explicit al beats the shape-derived default', () => {
    const cells = cellsIn(render(sheetOf({ rows: [['1,200', 'TRUE']], styles: { '0,0': { al: 'left' }, '0,1': { al: 'left' } } })))
    expect(cells.map((c) => c.align)).toEqual(['left', 'left'])
  })

  it('makes a whole-string http(s) cell tappable — and only that', () => {
    const values = [
      'https://example.com/a',
      'http://x.y',
      'HTTPS://X.Y',
      'see https://x.y',
      'javascript:alert(1)',
      'mailto:a@b.c',
      'example.com',
    ]
    const cells = cellsIn(render(sheetOf({ rows: [values] })))
    expect(cells.map((c) => c.pressable)).toEqual([true, true, true, false, false, false, false])
    expect(cells[0]?.color).toBe(theme.accent)
    expect(cells[0]?.underline).toBe('underline')
    expect(cells[3]?.color).toBe(theme.text)
    expect(cells[3]?.underline).toBeUndefined()
  })

  it('paints cell values in the mono face (.bp-sheet__td)', () => {
    for (const cell of cellsIn(render(sheetOf({ rows: [['a', 'b']] })))) expect(cell.face).toBe('monospace')
  })
})

describe('sheet — merges are a recorded NARROWING (D46b), not a silent loss', () => {
  // The covered cells of a merged range are already "" in the dense snapshot,
  // so ignoring `merges` renders every cell, shows the anchor value once, and
  // keeps the column geometry. The pin: adding merges changes NOTHING.
  const dense = { head: ['a', 'b', 'c'], rows: [['anchor', '', ''], ['x', 'y', 'z']] }

  it('renders identically with and without a merges array', () => {
    const plain = render(sheetOf(dense))
    const merged = render(sheetOf({ ...dense, merges: [[0, 0, 1, 3]] }))
    expect(gridRows(merged)).toEqual(gridRows(plain))
    expect(cellsIn(merged).map((c) => c.value)).toEqual(cellsIn(plain).map((c) => c.value))
  })

  it('shows the anchor value exactly once and keeps the geometry rectangular', () => {
    const out = render(sheetOf({ ...dense, merges: [[0, 0, 1, 3]] }))
    expect(cellsIn(out).filter((c) => c.value === 'anchor')).toHaveLength(1)
    for (const widths of gridRows(out)) expect(widths).toEqual([120, 120, 120])
  })
})

describe('sheet — unresolved and empty are different facts', () => {
  it('a ref with no snapshot says so', () => {
    expect(allText(render({ type: 'sheet', ref: 'sheet-1' }))).toBe('[sheet — unresolved]')
    expect(allText(render({ type: 'sheet', snapshot: [] }))).toBe('[sheet — unresolved]')
  })

  it('a resolved but empty snapshot says THAT', () => {
    expect(allText(render(sheetOf({})))).toBe('(empty sheet)')
    expect(allText(render(sheetOf({ head: [], rows: [] })))).toBe('(empty sheet)')
    expect(allText(render(sheetOf({ head: [], rows: [[]] })))).toBe('(empty sheet)')
  })
})

/* ══ task-board ═════════════════════════════════════════════════════════════ */

describe('task-board — seven lanes, ladder order, empties collapse (D46c)', () => {
  it('renders react BOARD_ROLES in ladder order', () => {
    const board = boardOf([
      { title: 'o', status: 'open' },
      { title: 'r', status: 'ready' },
      { title: 'p', status: 'in_progress' },
      { title: 'b', status: 'blocked' },
      { title: 'd', status: 'done' },
      { title: 'k', status: 'considering' },
      { title: 's', status: 'researching' },
    ])
    expect(lanesIn(render(board)).map((l) => l.label)).toEqual([
      'OPEN',
      'READY',
      'IN PROGRESS',
      'BLOCKED',
      'DONE',
      'CONSIDERING',
      'RESEARCHING',
    ])
  })

  it('is the SEVEN-role set, not the TUI five — the thought lanes exist', () => {
    const labels = lanesIn(render(boardOf([{ title: 'k', status: 'considering' }, { title: 's', status: 'researching' }]))).map(
      (l) => l.label,
    )
    expect(labels).toEqual(['CONSIDERING', 'RESEARCHING'])
  })

  it('collapses empty lanes', () => {
    const lanes = lanesIn(render(boardOf([{ title: 'r', status: 'ready' }, { title: 'd', status: 'done' }])))
    expect(lanes.map((l) => l.label)).toEqual(['READY', 'DONE'])
  })

  it('labels each lane with its count', () => {
    const lanes = lanesIn(
      render(boardOf([{ title: 'a', status: 'ready' }, { title: 'b', status: 'ready' }, { title: 'c', status: 'done' }])),
    )
    expect(lanes.map((l) => `${l.label} ${l.count}`)).toEqual(['READY 2', 'DONE 1'])
  })
})

describe('task-board — a row is NEVER dropped', () => {
  const ROWS: unknown[] = [
    { title: 'row-open', status: 'open' },
    { title: 'row-cancel', status: 'cancelled' },
    { title: 'row-weird', status: 'teleported' },
    { title: 'row-blank' },
    { title: 'row-done', status: 'closed' },
    'not-a-map',
  ]

  it('renders one card per input row — laneless roles and non-maps included', () => {
    const out = render(boardOf(ROWS))
    expect(cardCount(out)).toBe(ROWS.length)
    for (const title of ['row-open', 'row-cancel', 'row-weird', 'row-blank', 'row-done']) {
      expect(allText(out)).toContain(title)
    }
  })

  it('homes the laneless roles in OPEN — cancel and unknown are not lanes', () => {
    const lanes = lanesIn(render(boardOf(ROWS)))
    expect(lanes.map((l) => l.label)).toEqual(['OPEN', 'DONE'])
    const open = lanes[0]
    expect(open?.count).toBe('5')
    expect(open?.text).toContain('row-cancel')
    expect(open?.text).toContain('row-weird')
  })

  it('paints each row its OWN glyph, not the lane role (placement ⊥ styling)', () => {
    const open = lanesIn(render(boardOf(ROWS)))[0]
    // ○ open/blank/non-map · ✕ cancelled · ◦ the fail-open unknown sentinel —
    // all three sitting inside the ONE open lane.
    expect(open?.text).toContain('○')
    expect(open?.text).toContain('✕')
    expect(open?.text).toContain('◦')
  })

  it('the harness can fail: a dropped row would move the card count', () => {
    expect(cardCount(render(boardOf([{ title: 'x', status: 'ready' }])))).toBe(1)
    expect(cardCount(render(boardOf([])))).toBe(0)
  })
})

describe('task-board — card glyph, meta and hues', () => {
  it('carries priority, criteria and worker', () => {
    const out = allText(
      render(boardOf([{ title: 'T', status: 'ready', priority: 1, criteria: { met: 2, total: 5 }, worker: 'epic-b' }])),
    )
    expect(out).toContain('P1')
    expect(out).toContain('2/5')
    expect(out).toContain('epic-b')
  })

  it('falls back to P? for a non-numeric priority and drops an unusable criteria map', () => {
    const out = allText(render(boardOf([{ title: 'T', priority: 'urgent', criteria: { met: 0, total: 0 } }])))
    expect(out).toContain('P?')
    expect(out).not.toContain('0/0')
  })

  it('grades the priority chip by severity (danger / warn / faint)', () => {
    const colorOfPriority = (p: unknown): unknown => {
      let found: unknown
      visit(render(boardOf([{ title: 'T', priority: p }])), (el) => {
        if (allText(props(el).children as ReactNode) === (p === 3 ? 'P3' : p === 2 ? 'P2' : 'P1')) {
          found = flatStyle(props(el).style).color
        }
      })
      return found
    }
    expect(colorOfPriority(1)).toBe(theme.danger)
    expect(colorOfPriority(2)).toBe(theme.warn)
    expect(colorOfPriority(3)).toBe(theme.textMuted)
  })

  it('resolves the whole status ladder to a glyph — closed folds to done, blank to open', () => {
    const glyphFor = (status: unknown): string => firstText(render(boardOf([{ title: 'T', status }])) as ReactNode)
    // firstText reaches the lane LABEL first, so read the card glyph instead.
    const cardGlyph = (status: unknown): string => {
      let g = ''
      visit(render(boardOf([{ title: 'T', status }])), (el) => {
        if (flatStyle(props(el).style).borderRadius !== 7) return
        if (g === '') g = firstText(props(el).children as ReactNode)
      })
      return g
    }
    expect(glyphFor('open')).toBe('OPEN')
    expect(cardGlyph('open')).toBe('○')
    expect(cardGlyph('ready')).toBe('○')
    expect(cardGlyph('in_progress')).toBe('◐')
    expect(cardGlyph('blocked')).toBe('!')
    expect(cardGlyph('done')).toBe('✓')
    expect(cardGlyph('closed')).toBe('✓')
    expect(cardGlyph('cancelled')).toBe('✕')
    expect(cardGlyph('considering')).toBe('◌')
    expect(cardGlyph('researching')).toBe('◎')
    expect(cardGlyph('')).toBe('○')
    expect(cardGlyph('teleported')).toBe('◦')
  })
})

describe('task-board — unresolved and empty are different facts', () => {
  it('a query-driven board with no snapshot says unresolved', () => {
    expect(allText(render({ type: 'task-board', query: 'ready' }))).toBe('[task-board — unresolved]')
    expect(allText(render({ type: 'task-board', snapshot: {} }))).toBe('[task-board — unresolved]')
  })

  it('a resolved but empty snapshot says No tasks yet.', () => {
    expect(allText(render(boardOf([])))).toBe('No tasks yet.')
  })

  it('the tasks / task-list siblings keep their own empty state', () => {
    expect(allText(render({ type: 'tasks' }))).toBe('No tasks yet.')
    expect(allText(render({ type: 'task-list', snapshot: [] }))).toBe('No tasks yet.')
  })

  it('tasks and task-list stay ONE function; task-board is its own', () => {
    const out = allText(render({ type: 'tasks', snapshot: [{ title: 'T', status: 'closed' }] }))
    // the list's quieter two-tone rule: the done glyph, no lane chrome
    expect(out).toContain('✓')
    expect(lanesIn(render({ type: 'tasks', snapshot: [{ title: 'T', status: 'open' }] }))).toEqual([])
  })
})

/* ══ both registers (D50) ═══════════════════════════════════════════════════ */

describe('both grid natives render in BOTH registers', () => {
  const BLOCKS: Record<string, unknown>[] = [
    sheetOf({ head: ['Item'], rows: [['Widget', 'https://x.y']], col_widths: [90], styles: { '0,0': { b: true } } }),
    boardOf([
      { title: 'B', status: 'in_progress', priority: 2, criteria: { met: 1, total: 2 }, worker: 'w' },
      { title: 'C', status: 'cancelled' },
    ]),
  ]

  it('paints in both, degrades in neither', () => {
    for (const block of BLOCKS) {
      for (const ctx of [paper, chat]) {
        const out = render(block, ctx)
        expect(allText(out)).not.toContain('Unsupported block')
        expect(allText(out).trim()).not.toBe('')
      }
    }
  })

  it('never leaks the serif reading face into either register', () => {
    for (const block of BLOCKS) {
      for (const ctx of [paper, chat]) {
        expect(fontFamilies(render(block, ctx))).not.toContain('serif')
      }
    }
  })

  it('is REGISTER-BLIND by ruling — the two registers are byte-identical', () => {
    // Both types are table/cards-class chrome: paper-surface.css itself paints
    // .bp-sheet__td in mono and .bp-bcard__t BELOW the prose measure, so there
    // is no bodyText(ctx) run to carry. This pin IS the recorded per-type
    // REGISTER_BLIND ruling D50's crown tripwire asks for: if a later slice
    // makes either renderer register-aware, this reds and the ruling must be
    // revisited rather than drifting.
    for (const block of BLOCKS) {
      expect(styleCensus(render(block, chat))).toEqual(styleCensus(render(block, paper)))
      expect(allText(render(block, chat))).toEqual(allText(render(block, paper)))
    }
  })
})
