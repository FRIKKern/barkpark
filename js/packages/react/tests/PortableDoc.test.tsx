import { describe, it, expect } from 'vitest'
import { renderToStaticMarkup } from 'react-dom/server'
import { PortableDoc, renderPortableDocument, type Block } from '../src'
import { REGISTERED_TYPES } from '../src/blocks/registry'

// One authored block per IN-SCOPE type + the distinctive marker its :article
// render carries. The type-keyed prose core emits BARE semantic tags (no `bp-*`
// class — the `.bp-paper-surface` element rules own their typography, walk.ex
// theme-vs-data contract), so their marker is the tag; every richer block
// carries its `bp-*` wrapper class. The cross-surface byte/shape match against
// the Elixir golden is the SEPARATE parity-proof slice; this is the JS-side
// self-proof that all 46 render, without throwing, into the expected wrapper.
const CASES: Array<{ type: string; block: Block; marker: string }> = [
  { type: 'heading', block: { type: 'heading', level: 2, text: 'Title' }, marker: '<h2' },
  { type: 'eyebrow', block: { type: 'eyebrow', text: 'KICKER' }, marker: 'bp-role-eyebrow' },
  { type: 'byline', block: { type: 'byline', items: ['Ada', 'Grace'] }, marker: 'bp-role-byline' },
  {
    type: 'ingress',
    block: { type: 'ingress', content: [{ type: 'text', value: 'Lead.' }] },
    marker: 'bp-role-ingress',
  },
  {
    type: 'paragraph',
    block: { type: 'paragraph', content: [{ type: 'text', value: 'Body.' }] },
    marker: '<p>',
  },
  {
    type: 'pullquote',
    block: { type: 'pullquote', content: [{ type: 'text', value: 'Quote.' }] },
    marker: 'bp-role-pullquote',
  },
  {
    type: 'list',
    block: { type: 'list', ordered: false, items: [[{ type: 'text', value: 'one' }]] },
    marker: '<ul>',
  },
  {
    type: 'callout',
    block: {
      type: 'callout',
      tone: 'info',
      title: 'Note',
      content: [{ type: 'text', value: 'c' }],
    },
    marker: 'bp-callout',
  },
  { type: 'code', block: { type: 'code', value: 'x = 1' }, marker: '<pre' },
  { type: 'divider', block: { type: 'divider' }, marker: '§' },
  {
    type: 'image',
    block: { type: 'image', src: 'https://ex.com/a.png', alt: 'a', width: 10, height: 5 },
    marker: '<img',
  },
  {
    type: 'figure',
    block: {
      type: 'figure',
      caption: 'Figure 1. cap',
      child: { type: 'paragraph', content: [{ type: 'text', value: 'c' }] },
    },
    marker: '<figure',
  },
  {
    type: 'table',
    block: {
      type: 'table',
      head: [[{ type: 'text', value: 'H' }]],
      rows: [[[{ type: 'text', value: 'c' }]]],
    },
    marker: 'bp-table',
  },
  {
    type: 'section',
    block: {
      type: 'section',
      title: 'S',
      layout: { mode: 'grid', tracks: 2, gap: 'md' },
      blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'x' }] }],
    },
    marker: 'bp-section__grid',
  },
  {
    type: 'action',
    block: { type: 'action', href: '/go', label: 'Go', priority: 'primary' },
    marker: 'bp-button--primary',
  },
  {
    type: 'diagram',
    block: { type: 'diagram', source: 'graph TD; A-->B', caption: 'Figure 2. d' },
    marker: 'class="mermaid"',
  },
  {
    type: 'asciicast',
    block: { type: 'asciicast', src: 'https://ex.com/c.cast', caption: 'rec' },
    marker: 'bp-asciicast',
  },
  {
    type: 'columns',
    block: {
      type: 'columns',
      columns: [[{ type: 'paragraph', content: [{ type: 'text', value: 'a' }] }]],
    },
    marker: 'bp-cols',
  },
  {
    type: 'terminal',
    block: {
      type: 'terminal',
      title: 't',
      live: true,
      footer: 'f',
      children: [{ type: 'paragraph', content: [{ type: 'text', value: 'x' }] }],
    },
    marker: 'bp-term',
  },
  { type: 'status-legend', block: { type: 'status-legend' }, marker: 'bp-legend' },
  {
    type: 'notes',
    block: { type: 'notes', items: [{ label: 'L', lead: 'Ld', text: 't' }] },
    marker: 'bp-notes',
  },
  {
    type: 'note',
    block: { type: 'note', label: 'L', lead: 'Ld', text: 't' },
    marker: 'class="bp-note"',
  },
  {
    type: 'cards',
    block: { type: 'cards', items: [{ title: 'T', text: 'x', tone: 'info' }] },
    marker: 'bp-cards',
  },
  {
    type: 'card',
    block: {
      type: 'card',
      tone: 'info',
      slots: { title: [{ type: 'heading', level: 3, text: 'T' }] },
    },
    marker: 'bp-card--info',
  },
  {
    type: 'pipeline',
    block: { type: 'pipeline', nodes: [{ kind: 'k', title: 't', detail: 'd', source: true }] },
    marker: 'bp-pipe',
  },
  {
    type: 'stage',
    block: { type: 'stage', kind: 'k', title: 't', detail: 'd' },
    marker: 'bp-pnode',
  },
  {
    type: 'task-detail',
    block: {
      type: 'task-detail',
      task: {
        title: 'T',
        status: 'in_progress',
        priority: 1,
        criteria: [{ text: 'c', met: true, evidence: 'e' }],
      },
    },
    marker: 'bp-tdetail',
  },
  {
    type: 'roadmap',
    block: {
      type: 'roadmap',
      snapshot: [{ title: 'P', status: 'done', left: 0, width: 50, phase_row: true }],
      scale: ['Q1', 'Q2'],
      today: 30,
    },
    marker: 'bp-roadmap',
  },
  {
    type: 'task-board',
    block: { type: 'task-board', snapshot: [{ title: 'T', status: 'in_progress', priority: 1 }] },
    marker: 'bp-board',
  },
  {
    type: 'tasks',
    block: {
      type: 'tasks',
      title: 'List',
      snapshot: [{ title: 'T', status: 'ready', phase: 'P1' }],
    },
    marker: 'bp-tasks',
  },
  {
    type: 'task-list',
    block: { type: 'task-list', snapshot: [{ title: 'T', status: 'open' }] },
    marker: 'bp-tasks',
  },
  {
    type: 'stat',
    block: { type: 'stat', value: '42', label: 'Users', max: 100, denom: '118', spark: [1, 2, 3] },
    marker: 'bp-stat',
  },
  {
    type: 'stats',
    block: { type: 'stats', items: [{ value: '1', label: 'a' }] },
    marker: 'bp-stats',
  },
  {
    type: 'stat-grid',
    block: { type: 'stat-grid', items: [{ value: '2', label: 'b' }] },
    marker: 'bp-stats',
  },
  {
    type: 'heatmap',
    block: {
      type: 'heatmap',
      cells: [
        [1, 2],
        [3, 4],
      ],
      rowLabels: ['r1', 'r2'],
      colLabels: ['c1', 'c2'],
    },
    marker: 'bp-heat',
  },
  {
    type: 'chart',
    block: {
      type: 'chart',
      series: [{ label: 's1', points: [1, 2, 3] }],
      axes: { xLabels: ['a', 'b'] },
      caption: 'C',
    },
    marker: 'bp-chart',
  },
  {
    type: 'form',
    block: {
      type: 'form',
      kind: 'grill',
      questions: [{ id: 'q1', prompt: 'Ready?', type: 'yesno' }],
    },
    marker: 'bp-form-grill',
  },
  {
    type: 'questionnaire',
    block: {
      type: 'questionnaire',
      questions: [{ id: 'q2', prompt: 'Rate', type: 'scale', scale: { min: 1, max: 5 } }],
    },
    marker: 'bp-form-questionnaire',
  },
  {
    type: 'chat-thinking',
    block: { type: 'chat-thinking', tokens: 1500 },
    marker: 'bp-chat-thinking',
  },
  {
    type: 'chat-todo',
    block: {
      type: 'chat-todo',
      todos: [{ content: 'do', status: 'in_progress', active_form: 'doing' }],
    },
    marker: 'bp-chat-todo',
  },
  {
    type: 'chat-tool-diff',
    block: {
      type: 'chat-tool-diff',
      input: { file_path: 'a.txt', old_string: 'a\nb', new_string: 'a\nc' },
    },
    marker: 'bp-chat-tool-diff',
  },
  {
    type: 'chat-approval',
    block: { type: 'chat-approval', tool_name: 'Bash', summary: 'rm -rf x', approval_status: 'pending' },
    marker: 'bp-chat-approval',
  },
  {
    type: 'chat-question',
    block: {
      type: 'chat-question',
      questions: [{ question: 'Pick one?', options: ['A', 'B'] }],
      approval_status: 'pending',
    },
    marker: 'bp-chat-question',
  },
  {
    type: 'chat-plan',
    block: { type: 'chat-plan', title: 'The plan', preview: 'Do the thing.', approval_status: 'pending' },
    marker: 'bp-chat-plan',
  },
  {
    type: 'gauge-list',
    block: {
      type: 'gauge-list',
      title: 'By surface',
      rows: [
        { label: 'A', value: 2 },
        { label: 'B', value: 2 },
      ],
    },
    marker: 'bp-gauge',
  },
  {
    type: 'sheet',
    block: {
      type: 'sheet',
      snapshot: {
        head: ['A', 'B'],
        rows: [
          ['1', '2'],
          ['3', '4'],
        ],
      },
    },
    marker: 'bp-sheet__td',
  },
]

describe('PortableDoc — the type-keyed renderer', () => {
  it('wraps the document in the canonical .bp-paper-surface container', () => {
    const html = renderToStaticMarkup(
      <PortableDoc value={[{ type: 'paragraph', content: [{ type: 'text', value: 'hi' }] }]} />,
    )
    expect(html).toContain('class="bp-paper-surface"')
    expect(html).toContain('<p>hi</p>')
  })

  it('renders an empty document without throwing (honest empty surface)', () => {
    expect(renderToStaticMarkup(<PortableDoc value={[]} />)).toContain('class="bp-paper-surface"')
    expect(renderToStaticMarkup(<PortableDoc value={null} />)).toContain('class="bp-paper-surface"')
  })

  it('appends an extra className to the surface root', () => {
    const html = renderToStaticMarkup(<PortableDoc value={[]} className="prose" />)
    expect(html).toContain('class="bp-paper-surface prose"')
  })

  it.each(CASES)('renders $type into its expected wrapper', ({ block, marker }) => {
    const html = renderPortableDocument([block])
    expect(html).toContain(marker)
  })

  it('covers EXACTLY the 46 in-scope types (registry ≡ authored cases)', () => {
    const authored = CASES.map((c) => c.type).sort()
    const registered = [...REGISTERED_TYPES].sort()
    expect(authored).toEqual(registered)
    expect(registered).toHaveLength(46)
  })

  it('composes a whole kitchen-sink array in one render without throwing', () => {
    const html = renderToStaticMarkup(<PortableDoc value={CASES.map((c) => c.block)} />)
    expect(html.startsWith('<div class="bp-paper-surface">')).toBe(true)
    // every marker survives the full-document render
    for (const { marker } of CASES) expect(html).toContain(marker)
  })

  it('inline marks (D4): nested <span style> + bare <code>/<a>, never <strong>/<em>', () => {
    const html = renderPortableDocument([
      {
        type: 'paragraph',
        content: [
          { type: 'text', value: 'bold', marks: ['strong'] },
          { type: 'text', value: 'em', marks: ['em'] },
          { type: 'text', value: 'c', marks: ['code'] },
          { type: 'text', value: 'link', marks: [{ type: 'link', href: 'https://ex.com' }] },
          { type: 'text', value: 'plain' },
        ],
      },
    ])
    expect(html).toContain('<span style="font-weight:bold">bold</span>')
    expect(html).toContain('<span style="font-style:italic">em</span>')
    expect(html).toContain('<code>c</code>')
    expect(html).toContain(
      '<a href="https://ex.com" style="color:var(--paper-accent, #1e5347)">link</a>',
    )
    // bare text carries no wrapping span
    expect(html).toContain('plain</p>')
    // NEVER the Tailwind/web-fork element forms
    expect(html).not.toContain('<strong>')
    expect(html).not.toContain('<em>')
  })

  it('is type-keyed, NOT Sanity PortableText (a `_type:block` node degrades)', () => {
    // A Sanity-shaped block is not a registered type-keyed block → visible degrade,
    // proving PortableDoc does not double as the PortableText shim.
    const html = renderPortableDocument([{ type: '', _type: 'block' } as unknown as Block])
    expect(html).toContain('bp-unknown-block')
  })

  it('escapes hostile author strings (no markup injection)', () => {
    const html = renderPortableDocument([{ type: 'heading', level: 1, text: '<script>x</script>' }])
    expect(html).toContain('&lt;script&gt;')
    expect(html).not.toContain('<script>')
  })

  // ── Elixir-fidelity regressions caught by the cross-surface parity harness ──
  // These three shapes are where the JS renderer silently diverged from the
  // walk.ex / data_viz.ex / figures.ex golden; the parity-proof slice's harness
  // is the full guard, these pin the specific bytes on this slice's own gate.
  describe('parity fidelity vs the Elixir :article golden', () => {
    it('table cells wrap inline content in a <span> (render_children → walk PdText)', () => {
      const html = renderPortableDocument([
        {
          type: 'table',
          head: [[{ type: 'text', value: 'H' }]],
          rows: [[[{ type: 'text', value: 'c' }]]],
        },
      ])
      expect(html).toContain('<th class="bp-table__th"><span>H</span></th>')
      expect(html).toContain('<td class="bp-table__td"><span>c</span></td>')
    })

    it('heatmap normalizes --i by the grid max, not a 1.0 floor (data_viz heat_grid_html)', () => {
      // cells max 0.9 → 0.9/0.9 = 1.000 for the top cell, 0.1/0.9 = 0.111 for the low.
      const html = renderPortableDocument([{ type: 'heatmap', cells: [[0.1, 0.9]] }])
      expect(html).toContain('style="--i:1.000"')
      expect(html).toContain('style="--i:0.111"')
    })

    it('asciicast figcaption uses a plain color, not the var() the figure caption uses', () => {
      const html = renderPortableDocument([
        { type: 'asciicast', src: 'https://ex.com/c.cast', caption: 'rec' },
      ])
      expect(html).toContain('color:#55635e')
      expect(html).not.toContain(
        "color:var(--paper-ink-soft, #55635e);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif\">rec",
      )
    })
  })
})
