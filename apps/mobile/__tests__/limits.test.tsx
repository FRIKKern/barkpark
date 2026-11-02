import { act, create, type ReactTestRenderer, type ReactTestRendererJSON } from 'react-test-renderer'

import { diffWords, goldenWords, loadLimits } from '../../../api/priv/portable_doc/conformance/conformance.mjs'
import { renderBlockNative } from '../src/papers/portabledoc/blocks'
import { chartSpan, decodeRoutePolyline, heatWidths } from '../src/papers/portabledoc/blocks/dataviz'
import * as model from '../src/papers/portabledoc/model'
import { light } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

type Host = ReactTestRendererJSON | ReactTestRendererJSON[] | string | null

function textOf(node: Host): string {
  if (node === null) return ''
  if (typeof node === 'string') return node
  if (Array.isArray(node)) return node.map(textOf).join(' ')
  return (node.children ?? []).map(textOf).join(' ')
}

function mount(block: unknown, locale?: string): { text: string; tree: ReactTestRenderer } {
  let tree!: ReactTestRenderer
  act(() => {
    tree = create(<>{renderBlockNative(block, { theme: light, locale }, 0)}</>)
  })
  return { text: textOf(tree.toJSON()), tree }
}

function render(block: unknown, locale?: string): string {
  const { text, tree } = mount(block, locale)
  act(() => tree.unmount())
  return text
}

function cpuMs(since?: ReturnType<typeof process.cpuUsage>): number {
  const { user, system } = process.cpuUsage(since)
  return (user + system) / 1000
}

function timed(block: unknown): number {
  const started = process.cpuUsage()
  const { tree } = mount(block)
  const elapsed = cpuMs(started)
  act(() => tree.unmount())
  return elapsed
}

const { edges, docs } = loadLimits()

describe('PortableDoc render limits on mobile', () => {
  it.each(edges.map((e) => [e.name, e] as const))('edge %s answers like the reference', (_name, edge) => {
    const verdict = diffWords(render(edge.input), goldenWords(edge.shape))
    if (Array.isArray(verdict)) expect(verdict).toEqual([])
  })

  it.each(docs.map((d) => [d.name, d.doc] as const))('worst case %s renders in under a second', (_name, doc) => {
    expect(timed(doc)).toBeLessThan(1000)
  })
})

const NOTICE = 'Nested too deep to show'

function words(text: string): string[] {
  return text.split(/\s+/).filter(Boolean)
}

function recordTable(rows: number, columns: number) {
  return {
    type: 'table',
    columns: Array.from({ length: columns }, () => ({ key: 'k' })),
    rows: Array.from({ length: rows }, () => ({ k: 'x' })),
  }
}

describe('record tables', () => {
  it('draws a table of exactly 10000 cells', () => {
    expect(render(recordTable(100, 100))).not.toContain('Table too large to show')
  })

  it('shows the notice past 10000 cells', () => {
    expect(render(recordTable(101, 100)).trim()).toBe('Table too large to show')
  })

  it('never caps a plain table', () => {
    const rows = Array.from({ length: 101 }, () => Array.from({ length: 100 }, () => 'x'))
    expect(render({ type: 'table', rows })).not.toContain('Table too large to show')
  })

  it('shows the notice one cell past the cap', () => {
    expect(render(recordTable(10001, 1)).trim()).toBe('Table too large to show')
  })

  it('never caps a table whose columns all carry text', () => {
    const table = recordTable(101, 100)
    const columns = table.columns.map((column) => ({ ...column, text: 'K' }))
    expect(render({ ...table, columns })).not.toContain('Table too large to show')
  })

  it('says it in the workspace language', () => {
    expect(render(recordTable(101, 100), 'nb-NO').trim()).toBe('Tabellen er for stor til å vises')
  })
})

describe('toc depth', () => {
  const items = Array.from({ length: 8 }, (_, i) => ({ text: `h${i + 1}`, level: i + 1, anchor: `a${i + 1}` }))
  const toc = (depth: unknown) => words(render({ type: 'toc', items, depth }))

  it('clamps to six levels', () => {
    expect(toc(7)).toEqual(toc(6))
    expect(toc(6)).toEqual(['h1', 'h2', 'h3', 'h4', 'h5', 'h6'])
  })

  it('takes the default for a fraction, a string or zero', () => {
    expect(toc(2.5)).toEqual(['h1', 'h2'])
    expect(toc('3')).toEqual(['h1', 'h2'])
    expect(toc(0)).toEqual(['h1', 'h2'])
  })
})

describe('block nesting', () => {
  const slots: [string, string[]][] = [
    ['section', ['blocks', '*']],
    ['columns', ['columns', '*', '*']],
    ['terminal', ['blocks', '*']],
    ['terminal', ['children', '*']],
    ['expandable', ['blocks', '*']],
    ['expandable', ['children', '*']],
    ['tabs', ['tabs', '*', 'blocks', '*']],
    ['steps', ['steps', '*', 'blocks', '*']],
    ['steps', ['steps', '*', 'children', '*']],
    ['figure', ['child']],
    ['card', ['slots', 'action', '*']],
    ['card', ['slots', 'body', '*']],
    ['card', ['slots', 'media', '*']],
    ['card', ['slots', 'title', '*']],
    ['callout', ['slots', 'body', '*']],
    ['note', ['slots', 'body', '*']],
    ['note', ['slots', 'label', '*']],
    ['note', ['slots', 'lead', '*']],
    ['stage', ['slots', 'detail', '*']],
    ['stage', ['slots', 'kind', '*']],
    ['stage', ['slots', 'title', '*']],
    ...['list', 'ordered-list', 'numbered_list', 'bulletList', 'bullet_list', 'bulleted-list', 'bulleted_list'].map(
      (type): [string, string[]] => [type, ['items', '*', 'children', '*']],
    ),
  ]

  function wrap(type: string, path: string[], inner: unknown): unknown {
    const build = (rest: string[]): unknown => {
      const [head, ...tail] = rest
      if (head === undefined) return inner
      return head === '*' ? [build(tail)] : { [head]: build(tail) }
    }
    return { type, ...(build(path) as object) }
  }

  function leafAt(block: unknown, path: string[], levels: number): unknown {
    let node = block
    for (let i = 0; i < levels; i++) {
      for (const step of path) node = (node as Record<string | number, unknown>)[step === '*' ? 0 : step]
    }
    return node
  }

  function chain(type: string, path: string[], levels: number): unknown {
    let node: unknown = { type: 'paragraph', text: 'leaf' }
    for (let i = 0; i < levels; i++) node = wrap(type, path, node)
    return node
  }

  it.each(slots)('%s %j keeps depth 99 and replaces depth 100', (type, path) => {
    expect(leafAt(model.capDepth(chain(type, path, 99), NOTICE), path, 99)).toEqual({ type: 'paragraph', text: 'leaf' })
    expect(leafAt(model.capDepth(chain(type, path, 100), NOTICE), path, 100)).toEqual({ type: 'paragraph', text: NOTICE })
  })

  it('leaves a block outside the slot table alone', () => {
    const deep = chain('section', ['blocks', '*'], 100)
    const odd = { type: 'section', other: [deep] }
    expect(model.capDepth(odd, NOTICE)).toEqual(odd)
  })

  it('caps once at the top level and says it in the workspace language', () => {
    const text = render(chain('section', ['blocks', '*'], 100), 'nb-NO')
    expect(text).toContain('For dypt nestet til å vises')
    expect(text).not.toContain('leaf')
  })
})

describe('inline nesting', () => {
  const paragraph = (inline: unknown, locale?: string) => render({ type: 'paragraph', content: [inline] }, locale)
  const nest = (levels: number, node: (inner: unknown) => unknown) => {
    let inline: unknown = { type: 'text', value: 'leaf' }
    for (let i = 0; i < levels; i++) inline = node(inline)
    return inline
  }

  it.each([
    ['link', (inner: unknown) => ({ type: 'link', href: 'https://x.test', children: [inner] })],
    ['wikilink', (inner: unknown) => ({ type: 'wikilink', target: 't', children: [inner] })],
    ['unknown', (inner: unknown) => ({ type: 'mystery', children: [inner] })],
    ['typeless', (inner: unknown) => ({ children: [inner] })],
    ['underline', (inner: unknown) => ({ type: 'underline', children: [inner] })],
  ])('%s at depth 99 shows the leaf, at 100 the notice', (_name, node) => {
    expect(paragraph(nest(99, node))).toContain('leaf')
    expect(paragraph(nest(100, node))).toContain(NOTICE)
    expect(paragraph(nest(100, node))).not.toContain('leaf')
  })

  it('counts marks into the depth', () => {
    const marked = (n: number) => ({ type: 'text', value: 'leaf', marks: Array.from({ length: n }, () => 'em') })
    const deep = (marks: number) => {
      let inline: unknown = marked(marks)
      for (let i = 0; i < 50; i++) inline = { type: 'em', children: [inline] }
      return inline
    }
    expect(paragraph(deep(49))).toContain('leaf')
    expect(paragraph(deep(50))).toContain(NOTICE)
  })

  it('says it in the workspace language', () => {
    expect(paragraph(nest(100, (inner) => ({ type: 'em', children: [inner] })), 'nb-NO')).toContain(
      'For dypt nestet til å vises',
    )
  })
})

describe('heatmap padding budget', () => {
  it('pads while the padding fits in the stored cells, then leaves a gap', () => {
    expect(heatWidths([[1, 2, 3, 4, 5], [6], [7]], 5)).toEqual([5, 5, 1])
    expect(heatWidths([[1, 2, 3], [4]], 3)).toEqual([3, 3])
    expect(heatWidths([[1, 1, 1, 1], [1], [1]], 4)).toEqual([4, 4, 4])
  })

  it('shows padded zeros only where the reference pads', () => {
    const text = render({ type: 'heatmap', values: true, cells: [[1, 2, 3, 4, 5], [6], [7]] })
    expect(words(text).filter((w) => /^\d+$/.test(w))).toEqual(['1', '2', '3', '4', '5', '6', '0', '0', '0', '0', '7'])
  })
})

describe('numbers', () => {
  it('leaves out a value past the range or past what a float holds', () => {
    const big = JSON.parse(`[1, ${'9'.repeat(401)}, 1e101, 1e-101, 3]`)
    const shown = render({ type: 'heatmap', values: true, cells: [big] })
    expect(words(shown).filter((w) => /^\d+$/.test(w))).toEqual(['1', '0', '0', '0', '3'])
  })

  it('leaves out a value below the range', () => {
    const chart = (points: unknown[]) => render({ type: 'chart', series: [{ label: 's', points }] })
    expect(chart([1e-101, '1e-101'])).toBe(chart([]))
    expect(chart([1e-100])).not.toBe(chart([]))
  })

  it('draws no stat bar for a max past the range', () => {
    const tree = (block: object) => {
      const { tree: t } = mount({ type: 'stat', value: '5', ...block })
      const json = JSON.stringify(t.toJSON())
      act(() => t.unmount())
      return json
    }
    expect(tree({ max: 1e101 })).toBe(tree({}))
    expect(tree({ max: 1e100 })).not.toBe(tree({}))
  })

  it('keeps 0 and the range ends', () => {
    const shown = render({ type: 'heatmap', values: true, cells: [[0, 1e-100, '1e100']] })
    expect(shown).toContain(
      '10000000000000000159028911097599180468360808563945281389781327557747838772170381060813469985856815104',
    )
  })

  it('opens a flat line wide enough to divide at a large value', () => {
    const [lo, hi] = chartSpan([{ label: 's', points: [1e100, 1e100] }], {})
    expect(hi).toBeGreaterThan(lo)
    expect(chartSpan([{ label: 's', points: [4, 4] }], {})).toEqual([4, 5])
  })
})

describe('route polyline', () => {
  it('decodes a value of seven groups past 32 bits', () => {
    expect(decodeRoutePolyline('~~~~~~^?')).toEqual([[-(2 ** 34) / 1e5, 0]])
  })

  it('drops the tail at a value past seven groups', () => {
    expect(decodeRoutePolyline('??' + '~'.repeat(7) + '??')).toEqual([[0, 0]])
  })
})

describe('depth cap per document', () => {
  it('runs once for a nested document, not once per nested block', () => {
    const spy = jest.spyOn(model, 'capDepth')
    const doc = Array.from({ length: 50 }).reduce<unknown>(
      (inner) => ({ type: 'section', blocks: [inner] }),
      { type: 'paragraph', text: 'leaf' },
    )
    expect(render(doc)).toContain('leaf')
    expect(spy).toHaveBeenCalledTimes(1)
    spy.mockRestore()
  })
})

describe('deep values', () => {
  const deepArrays = (depth: number): unknown => Array.from({ length: depth }).reduce<unknown>((inner) => [inner], 'a')

  it('reads a code chip over deeply nested children as its text', () => {
    expect(render({ type: 'paragraph', content: [{ type: 'code', children: [deepArrays(20000)] }] })).toContain('a')
  })

  it('reads nothing from code children given as one node, not a list', () => {
    const text = render({ type: 'paragraph', content: ['before ', { type: 'code', children: { type: 'text', value: 'hidden' } }] })
    expect(text).toContain('before')
    expect(text).not.toContain('hidden')
  })

  it('reads a deeply nested list value as its text', () => {
    const text = render({ type: 'arrayOf', label: 'L', value: [deepArrays(20000), { b: [1, 2], a: true }] })
    expect(text).toContain('1. a')
    expect(text).toContain('2. a: Yes, b: 1, 2')
  })
})
