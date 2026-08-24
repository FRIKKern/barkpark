// Native PortableDoc renderer laws (mob-w2-paper-reader, criterion 1):
//
//   • the COMMITTED 104-block capstone renders with 0 empty blocks and 0
//     unknown-fallback blocks — the 16 content[]-shaped headings especially
//     (charter D12: reading `b.text` alone renders them empty),
//   • the content||text fallback law on heading/paragraph,
//   • list-item normalization across all four live authored shapes,
//   • inline mark folding + the safe-URL tap gate,
//   • the honest labeled fallback for unknown block types (logged once).
//
// The suite walks the element trees the PURE renderers return — no native
// host, no react-test-renderer: block renderers are hook-free by design (the
// one stateful leaf, MermaidIsland, is treated as a leaf and asserted by
// element type + props).
import type { ReactElement, ReactNode } from 'react'

import { MermaidIsland, islandHtml, scriptStringLiteral } from '../src/papers/portabledoc/MermaidIsland'
import {
  BLOCK_RENDERERS,
  renderBlockNative,
  resetUnknownBlockLog,
  type BlockCtx,
} from '../src/papers/portabledoc/blocks'
import {
  headingLevel,
  itemInlines,
  normalizeListItem,
  openableUrl,
  paragraphInline,
} from '../src/papers/portabledoc/model'
import { light, type Theme } from '../src/ui/theme'

// react-native-webview is a native TurboModule with no jest mock of its own;
// the suite never renders the island (stateful leaf), so a null stub is
// honest. jest hoists this above the imports.
jest.mock('react-native-webview', () => ({ WebView: () => null }))

const capstone = require('../../../tooling/webview-spike/assets/capstone.json') as {
  blocks: ({ type: string } & Record<string, unknown>)[]
}

// The REAL light palette, not a literal duplicate: the suite predates the
// tsconfig __tests__/**/*.tsx include and its hand-copied mock silently
// drifted (it lacked the #6126 `bubble` role — the live proof the gate was
// typecheck-blind). Importing from theme.ts means future role additions can
// never drift here silently again.
const theme: Theme = light
const ctx: BlockCtx = { theme }

/* ── element-tree walker ────────────────────────────────────────────────────── */

interface Walk {
  /** every string leaf, concatenated in tree order */
  text: string
  /** MermaidIsland elements found (leaves — never descended into) */
  islands: Record<string, unknown>[]
  /** count of elements of any kind (a text-free block still paints these) */
  elements: number
  /** onPress handlers seen on Text elements (the link tap gate) */
  pressables: number
}

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string') {
    acc.text += node
    return
  }
  if (typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (isElement(node)) {
    acc.elements += 1
    const props = node.props as Record<string, unknown>
    if (node.type === MermaidIsland) {
      acc.islands.push(props)
      return // stateful leaf — do not descend
    }
    if (typeof props.onPress === 'function') acc.pressables += 1
    walkNode(props.children as ReactNode, acc)
  }
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', islands: [], elements: 0, pressables: 0 }
  walkNode(node, acc)
  return acc
}

function render(block: unknown): Walk {
  return walk(renderBlockNative(block, ctx, 0))
}

beforeEach(() => {
  resetUnknownBlockLog()
})

/* ── the capstone corpus (criterion 1) ──────────────────────────────────────── */

describe('capstone fixture — 104 blocks, 0 empty, 0 unknown', () => {
  it('is the committed 104-block corpus', () => {
    expect(capstone.blocks).toHaveLength(104)
  })

  it('every block type is registered — no unknown fallback fires', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    for (const block of capstone.blocks) {
      expect(BLOCK_RENDERERS[block.type]).toBeDefined()
      const w = render(block)
      expect(w.text).not.toContain('Unsupported block')
    }
    expect(warn).not.toHaveBeenCalled()
    warn.mockRestore()
  })

  it('renders 0 empty blocks: every block paints text or a visual element', () => {
    for (const [i, block] of capstone.blocks.entries()) {
      const w = render(block)
      const painted = w.text.trim() !== '' || w.islands.length > 0 || w.elements > 0
      expect(painted ? 'painted' : `EMPTY block ${i} (${block.type})`).toBe('painted')
      // Stronger: everything except pure-visual types must carry text.
      if (block.type !== 'divider' && block.type !== 'diagram') {
        expect(w.text.trim() === '' ? `NO TEXT in block ${i} (${block.type})` : 'has-text').toBe('has-text')
      }
    }
  })

  it('all 16 headings render non-empty (the D12 content[] law)', () => {
    const headings = capstone.blocks.filter((b) => b.type === 'heading')
    expect(headings).toHaveLength(16)
    for (const h of headings) {
      expect(render(h).text.trim()).not.toBe('')
    }
  })

  it('the 3 mermaid diagrams mount as per-diagram islands with their source', () => {
    const diagrams = capstone.blocks.filter((b) => b.type === 'diagram')
    expect(diagrams).toHaveLength(3)
    for (const d of diagrams) {
      const w = render(d)
      expect(w.islands).toHaveLength(1)
      expect(w.islands[0]?.source).toBe(d.source)
    }
  })

  it('the query-driven task-list renders the honest empty state', () => {
    const tl = capstone.blocks.find((b) => b.type === 'task-list')
    expect(tl).toBeDefined()
    expect(render(tl).text).toContain('No tasks yet.')
  })
})

/* ── the content||text fallback law ─────────────────────────────────────────── */

describe('content||text law (D12)', () => {
  it('a non-empty content[] wins over text', () => {
    expect(
      paragraphInline({ content: [{ type: 'text', value: 'from content' }], text: 'from text' }),
    ).toEqual([{ type: 'text', value: 'from content' }])
  })

  it('falls back to text when content is absent or empty', () => {
    expect(paragraphInline({ text: 'bare text' })).toBe('bare text')
    expect(paragraphInline({ content: [], text: 'bare text' })).toBe('bare text')
  })

  it('renders [] when both are missing', () => {
    expect(paragraphInline({})).toEqual([])
  })

  it('heading level law: 1|2|3 as number or string, else 2', () => {
    expect(headingLevel({ level: 1 })).toBe(1)
    expect(headingLevel({ level: '3' })).toBe(3)
    expect(headingLevel({ level: 7 })).toBe(2)
    expect(headingLevel({})).toBe(2)
  })

  it('heading renders content[] shape (the capstone shape)', () => {
    const w = render({ type: 'heading', level: 2, content: [{ type: 'text', value: 'The heading' }] })
    expect(w.text).toBe('The heading')
  })

  it('heading renders bare-text shape', () => {
    expect(render({ type: 'heading', level: 2, text: 'Bare heading' }).text).toBe('Bare heading')
  })
})

/* ── list item shapes (live-corpus census: array / map / JSON string / string) ─ */

describe('list item normalization', () => {
  it('map items route through content||text (the dominant live shape)', () => {
    expect(itemInlines({ content: [{ type: 'text', value: 'map item' }] })).toEqual([
      { type: 'text', value: 'map item' },
    ])
    expect(itemInlines({ text: 'map text item' })).toBe('map text item')
  })

  it('JSON-encoded string items decode to their inline array', () => {
    const encoded = JSON.stringify([{ type: 'text', value: 'decoded' }])
    expect(normalizeListItem(encoded)).toEqual([{ type: 'text', value: 'decoded' }])
  })

  it('plain string items stay plain', () => {
    expect(normalizeListItem('plain item')).toBe('plain item')
    expect(normalizeListItem('[not json')).toBe('[not json')
  })

  it('a list block renders every authored shape non-empty', () => {
    const w = render({
      type: 'list',
      items: [
        'plain',
        [{ type: 'text', value: 'array item' }],
        { content: [{ type: 'text', value: 'map item' }] },
        JSON.stringify([{ type: 'text', value: 'json item' }]),
      ],
    })
    for (const expected of ['plain', 'array item', 'map item', 'json item']) {
      expect(w.text).toContain(expected)
    }
  })

  it('numbered_list alias renders ordered markers', () => {
    const w = render({ type: 'numbered_list', items: ['a', 'b'] })
    expect(w.text).toContain('1.')
    expect(w.text).toContain('2.')
  })
})

/* ── inline marks + link gate ───────────────────────────────────────────────── */

describe('inline marks', () => {
  it('marked text renders its value with mark wrappers', () => {
    const w = render({
      type: 'paragraph',
      content: [
        { type: 'text', value: 'bolded', marks: ['bold'] },
        { type: 'text', value: ' and ' },
        { type: 'text', value: 'coded', marks: ['code'] },
      ],
    })
    expect(w.text).toBe('bolded and coded')
  })

  it('an http link is tappable', () => {
    const w = render({
      type: 'paragraph',
      content: [{ type: 'text', value: 'open me', marks: [{ type: 'link', href: 'https://example.com' }] }],
    })
    expect(w.pressables).toBe(1)
    expect(w.text).toBe('open me')
  })

  it('a javascript: link renders its label but is NOT tappable', () => {
    const w = render({
      type: 'paragraph',
      content: [{ type: 'text', value: 'label survives', marks: [{ type: 'link', href: 'javascript' + ':alert(1)' }] }],
    })
    expect(w.pressables).toBe(0)
    expect(w.text).toBe('label survives')
  })

  it('openableUrl gate: only http(s)/mailto/tel pass', () => {
    expect(openableUrl('https://x.dev')).toBe('https://x.dev')
    expect(openableUrl('mailto:a@b.c')).toBe('mailto:a@b.c')
    expect(openableUrl('javascript' + ':alert(1)')).toBeUndefined()
    expect(openableUrl('//host/protocol-relative')).toBeUndefined()
    expect(openableUrl('/relative')).toBeUndefined()
    expect(openableUrl('\t javascript:x')).toBeUndefined()
  })

  it('inline code NODE renders its value', () => {
    const w = render({ type: 'paragraph', content: [{ type: 'code', value: 'inline_code()' }] })
    expect(w.text).toBe('inline_code()')
  })

  it('unknown inline degrades to its children, never vanishes wholesale', () => {
    const w = render({
      type: 'paragraph',
      content: [{ type: 'mystery-inline', children: [{ type: 'text', value: 'still here' }] }],
    })
    expect(w.text).toBe('still here')
  })
})

/* ── tables ─────────────────────────────────────────────────────────────────── */

describe('table', () => {
  it('renders head + rows, and honors the legacy header alias', () => {
    const block = {
      type: 'table',
      head: [[{ type: 'text', value: 'Col A' }], [{ type: 'text', value: 'Col B' }]],
      rows: [
        [[{ type: 'text', value: 'a1' }], [{ type: 'text', value: 'b1' }]],
        [['bare string cell'], [{ type: 'text', value: 'b2' }]],
      ],
    }
    const w = render(block)
    for (const s of ['Col A', 'Col B', 'a1', 'b1', 'bare string cell', 'b2']) {
      expect(w.text).toContain(s)
    }
    const aliased = render({ ...block, head: undefined, header: block.head })
    expect(aliased.text).toContain('Col A')
  })
})

/* ── unknown block degrade ──────────────────────────────────────────────────── */

describe('unknown blocks', () => {
  // THE SPECIMENS ARE DELIBERATE (mob-zb-s5). This test used `gauge-list` and
  // `chart` until those became real renderers, which disarmed it silently — the
  // fallback assertions simply stopped describing a fallback. `embed` and
  // `dashboard` cannot repeat that: they are D48's RECORDED exclusions —
  // server/Go-registry types with no @barkpark/react emitter — and mobile's
  // registry is react ∖ EXCLUSIONS, so no renderer slice can ever claim them.
  it('renders the honest labeled fallback and logs once per type', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    const first = render({ type: 'embed', items: [] })
    expect(first.text).toContain('Unsupported block: embed')
    render({ type: 'embed' })
    render({ type: 'embed' })
    expect(warn).toHaveBeenCalledTimes(1)
    render({ type: 'dashboard' })
    expect(warn).toHaveBeenCalledTimes(2)
    warn.mockRestore()
  })

  it('an invalid (non-map) block degrades, never throws', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    expect(render(null).text).toContain('Unsupported block')
    expect(render('junk').text).toContain('Unsupported block')
    warn.mockRestore()
  })

  it('a known type with a throwing payload degrades to the labeled fallback', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    // toc with a poisoned items getter — the renderer must catch, not crash.
    const poisoned = {
      type: 'toc',
      get items(): unknown {
        throw new Error('boom')
      },
    }
    expect(render(poisoned).text).toContain('Unsupported block: toc')
    warn.mockRestore()
  })
})

/* ── mermaid island HTML: author content stays inside the script string (F1) ── */

describe('mermaid island script injection (F1)', () => {
  it('escapes "<" so a </script> in the source cannot terminate the script', () => {
    const hostile = 'flowchart TD\n  A["</script><img src=x onerror=alert(1)>"] --> B'
    const literal = scriptStringLiteral(hostile)
    expect(literal).not.toContain('<')
    expect(literal).toContain('\\u003c')
    // Round-trips: the browser's JS engine reads back the exact author bytes.
    expect(JSON.parse(literal)).toBe(hostile)
  })

  it('the island HTML carries no raw author "<" — only the two known tags', () => {
    const hostile = 'A --> B\n</script><script>alert(1)</script>'
    const html = islandHtml(hostile, theme)
    // The ONLY </script> occurrences are the document's own two closers
    // (CDN include + inline bootstrap) — none from author content.
    expect(html.match(/<\/script>/g)).toHaveLength(2)
    expect(html).not.toContain('alert(1)</script>')
    expect(html).toContain('\\u003c')
    // CSP meta is present and locked to the CDN.
    expect(html).toContain('Content-Security-Policy')
    expect(html).toContain("script-src https://cdn.jsdelivr.net 'unsafe-inline'")
  })
})

/* ── image src resolution (F2): root-relative is the dominant live shape ────── */

describe('image src resolution (F2)', () => {
  const withBase: BlockCtx = { theme, serverBase: 'https://guerrilla.barkpark.cloud/' }

  function renderWith(block: unknown, c: BlockCtx): Walk {
    return walk(renderBlockNative(block, c, 0))
  }

  it('root-relative /media src resolves against the server base', () => {
    const el = renderBlockNative(
      { type: 'image', src: '/media/files/abc.png', alt: 'a chart' },
      withBase,
      0,
    )
    // The Image element's uri carries the joined absolute URL.
    const props = (el as { props: { source: { uri: string } } }).props
    expect(props.source.uri).toBe('https://guerrilla.barkpark.cloud/media/files/abc.png')
  })

  it('absolute https src passes through untouched', () => {
    const el = renderBlockNative(
      { type: 'image', src: 'https://example.com/x.png' },
      withBase,
      0,
    )
    const props = (el as { props: { source: { uri: string } } }).props
    expect(props.source.uri).toBe('https://example.com/x.png')
  })

  it('unresolvable src renders a labeled placeholder, never null', () => {
    // No serverBase in ctx → the root-relative src cannot resolve.
    const w = renderWith({ type: 'image', src: '/media/files/abc.png' }, { theme })
    expect(w.text).toContain('Image unavailable')
    expect(w.text).toContain('/media/files/abc.png')
    // Protocol-relative and hostile schemes also land on the placeholder.
    expect(renderWith({ type: 'image', src: '//evil.example/x.png' }, withBase).text).toContain(
      'Image unavailable',
    )
    expect(
      renderWith({ type: 'image', src: 'javascript' + ':alert(1)' }, withBase).text,
    ).toContain('Image unavailable')
  })

  it('asset-less image (empty src) still renders nothing — editor scaffolding', () => {
    expect(renderBlockNative({ type: 'image', src: '' }, withBase, 0)).toBeNull()
  })
})

/* ── related Paper cards ───────────────────────────────────────────────────── */

describe('paper-links', () => {
  const block = {
    type: 'paper-links',
    title: 'Continue reading',
    description: 'Useful context for this change.',
    refs: [
      {
        slug: 'paper-authoring-excellence',
        title: 'Authored fallback title',
        description: 'Authored fallback summary.',
        reason: 'See how the writing system works.',
      },
    ],
  }

  it('renders authored details offline without pretending the link is tappable', () => {
    const w = walk(renderBlockNative(block, { theme }, 0))
    expect(w.text).toContain('Continue reading')
    expect(w.text).toContain('Authored fallback title')
    expect(w.text).toContain('Authored fallback summary.')
    expect(w.text).toContain('See how the writing system works.')
    expect(w.pressables).toBe(0)
  })

  it('prefers live metadata and becomes tappable when connected to a server', () => {
    const w = walk(
      renderBlockNative(
        {
          ...block,
          _paper_links: {
            'paper-authoring-excellence': {
              title: 'Live Paper title',
              description: 'Freshly resolved summary.',
              event_type: 'paper_updated',
              rev: 7,
            },
          },
        },
        { theme, serverBase: 'https://guerrilla.barkpark.cloud/' },
        0,
      ),
    )
    expect(w.text).toContain('Live Paper title')
    expect(w.text).toContain('Freshly resolved summary.')
    expect(w.text).toContain('paper updated · revision 7')
    expect(w.text).not.toContain('Authored fallback summary.')
    expect(w.pressables).toBe(1)
  })

  it('drops invalid refs and renders nothing when none remain', () => {
    expect(renderBlockNative({ type: 'paper-links', refs: [{ slug: '../escape' }] }, { theme }, 0)).toBeNull()
  })
})

/* ── honest states for data-driven blocks ───────────────────────────────────── */

describe('data-driven honest states', () => {
  it('stats with no items says so', () => {
    expect(render({ type: 'stats', items: [] }).text).toContain('stats — no data')
  })

  it('stats renders value/denom/label', () => {
    const w = render({
      type: 'stats',
      items: [{ value: '3', denom: '7', label: 'criteria met' }],
    })
    for (const s of ['3', '7', 'criteria met']) expect(w.text).toContain(s)
  })

  it('task-list with a snapshot renders rows with glyphs', () => {
    const w = render({
      type: 'task-list',
      snapshot: [
        { title: 'done thing', status: 'done' },
        { title: 'open thing', status: 'open' },
      ],
    })
    expect(w.text).toContain('done thing')
    expect(w.text).toContain('✓')
    expect(w.text).toContain('○')
  })
})
