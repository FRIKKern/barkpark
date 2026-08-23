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
// self-proof that every registered type renders, without throwing, into its
// expected wrapper. Count via Object.keys(DISPATCH) — never trust a literal.
const CASES: Array<{ type: string; block: Block; marker: string }> = [
  { type: 'heading', block: { type: 'heading', level: 2, text: 'Title' }, marker: '<h2' },
  // scaffy:add-block-type Tabs MARK:js-case-tabs
  {
    type: 'tabs',
    block: {
      type: 'tabs',
      tabs: [
        {
          label: 'macOS',
          blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'brew install barkpark' }] }],
        },
        {
          label: 'Linux',
          blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'curl -fsSL install.sh | sh' }] }],
        },
      ],
    },
    marker: 'bp-tabs',
  },
  // scaffy:add-block-type CodeTabs MARK:js-case-code-tabs
  {
    type: 'code-tabs',
    block: {
      type: 'code-tabs',
      syncKey: 'lang',
      tabs: [
        { label: 'JS', language: 'js', value: 'console.log(1)' },
        { label: 'Go', language: 'go', value: 'fmt.Println(1)' },
      ],
    },
    marker: 'bp-code-tabs',
  },
  // scaffy:add-block-type ApiEndpoint MARK:js-case-api-endpoint
  {
    type: 'api-endpoint',
    block: {
      type: 'api-endpoint',
      method: 'POST',
      path: '/v1/data/mutate',
      params: [{ name: 'dataset', in: 'path', type: 'string', required: true }],
    },
    marker: 'bp-api-endpoint',
  },
  // scaffy:add-block-type Video MARK:js-case-video
  {
    type: 'video',
    block: {
      type: 'video',
      src: 'https://ex.com/demo.mp4',
      poster: 'https://ex.com/demo-poster.jpg',
      captions: [{ lang: 'en', src: 'https://ex.com/en.vtt' }],
    },
    marker: '<video',
  },
  // scaffy:add-block-type CriteriaProgress MARK:js-case-criteria-progress
  {
    type: 'criteria-progress',
    block: {
      type: 'criteria-progress',
      rows: [
        { label: 'Survey every corpus chapter', met: 2, total: 5 },
        { label: 'File child tasks', met: 5, total: 5 },
      ],
    },
    marker: 'bp-criteria-progress',
  },
  // scaffy:add-block-type Equation MARK:js-case-equation
  { type: 'equation', block: { type: 'equation', tex: 'E = mc^2' }, marker: 'bp-equation' },
  // scaffy:add-block-type BarChart MARK:js-case-bar-chart
  {
    type: 'bar-chart',
    block: {
      type: 'bar-chart',
      bars: [
        { label: 'paragraph', value: 4969 },
        { label: 'heading', value: 3232 },
      ],
    },
    marker: 'bp-bar-chart',
  },
  // scaffy:add-block-type Expandable MARK:js-case-expandable
  {
    type: 'expandable',
    block: {
      type: 'expandable',
      summary: 'Show the full trace',
      open: false,
      blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'Hidden detail.' }] }],
    },
    marker: 'bp-expandable',
  },
  // scaffy:add-block-type Footnote MARK:js-case-footnote
  {
    type: 'footnote',
    block: { type: 'footnote', notes: [{ id: 'fn1', text: 'A reference note.' }] },
    marker: 'bp-footnote',
  },
  // scaffy:add-block-type Steps MARK:js-case-steps
  {
    type: 'steps',
    block: {
      type: 'steps',
      steps: [
        { title: 'Claim the task', blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'Run bp task next.' }] }] },
        { title: 'Stamp evidence' },
      ],
    },
    marker: 'bp-steps',
  },
  // scaffy:add-block-type Toc MARK:js-case-toc
  {
    type: 'toc',
    block: {
      type: 'toc',
      items: [{ text: 'Getting started', level: 2, anchor: 'getting-started' }],
    },
    marker: 'bp-toc',
  },
  // scaffy:add-block-type Blockquote MARK:js-case-blockquote
  {
    type: 'blockquote',
    block: { type: 'blockquote', content: [{ type: 'text', value: 'Invent it.' }], cite: 'Alan Kay' },
    marker: 'bp-blockquote__cite',
  },
  // authoring-drift aliases → list / blockquote (compose.ex alias choke point twins)
  {
    type: 'bulletList',
    block: { type: 'bulletList', items: [[{ type: 'text', value: 'camelCase point' }]] },
    marker: 'camelCase point',
  },
  {
    type: 'bullet_list',
    block: { type: 'bullet_list', items: ['[{"type":"text","value":"json-encoded point"}]'] },
    marker: 'json-encoded point',
  },
  {
    type: 'bulleted-list',
    block: { type: 'bulleted-list', items: [[{ type: 'text', value: 'kebab point' }]] },
    marker: 'kebab point',
  },
  {
    type: 'bulleted_list',
    block: { type: 'bulleted_list', items: ['plain string point'] },
    marker: 'plain string point',
  },
  {
    type: 'numbered_list',
    block: { type: 'numbered_list', items: [[{ type: 'text', value: 'ordered point' }]] },
    marker: '<ol>',
  },
  {
    type: 'quote',
    block: { type: 'quote', content: [{ type: 'text', value: 'quoted words' }] },
    marker: 'bp-blockquote',
  },
  // h-tag + ordered-list drift (charter D57). The markers are the CLOSING tags,
  // so a level that came from the default rather than from the type reds: the h2
  // and h3 cases deliberately carry NO `level` key, which is the live shape.
  { type: 'h1', block: { type: 'h1', level: 1, text: 'drifted h1' }, marker: '</h1>' },
  { type: 'h2', block: { type: 'h2', text: 'drifted h2' }, marker: '</h2>' },
  { type: 'h3', block: { type: 'h3', text: 'drifted h3' }, marker: '</h3>' },
  {
    type: 'ordered-list',
    block: { type: 'ordered-list', items: [{ content: [{ type: 'text', value: 'kebab ordered point' }] }] },
    marker: '<ol>',
  },
  // scaffy:add-block-type Filetree MARK:js-case-filetree
  {
    type: 'filetree',
    block: {
      type: 'filetree',
      text: 'lib/\n├── components.ex ● diff_html/1\n└── stub.ex ✕ removed',
      legend: '● created · ✕ removed',
    },
    marker: 'bp-filetree',
  },
  // scaffy:add-block-type Diff MARK:js-case-diff
  {
    type: 'diff',
    block: {
      type: 'diff',
      file: 'lib/render/compose.ex',
      lang: 'elixir',
      diff: '--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1,2 +1,2 @@\n context\n-old line\n+new line',
    },
    marker: 'bp-diff',
  },
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
    type: 'duel',
    block: {
      type: 'duel',
      legendA: 'Med katalogen',
      legendB: 'Bare hendene',
      rows: [{ label: 'jobb', delta: '−30 %', valueA: '1 478', valueB: '2 121', source: 'commit:591fdcd53' }],
    },
    marker: 'bp-duel',
  },
  {
    type: 'lineage',
    block: {
      type: 'lineage',
      sourceDefault: 'paper:scaffy-benchmark',
      nodes: [{ overline: '2026', title: 'Scaffy', value: '22', unit: 'kommandoer', body: 'B' }],
    },
    marker: 'bp-lineage',
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
    type: 'field-number',
    block: { type: 'field-number', label: 'Price', value: 19.99, unit: 'NOK' },
    marker: 'bp-field',
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
    type: 'route',
    block: {
      type: 'route',
      sport: 'sykling',
      distance: '4.2 km',
      // the Google reference-vector polyline — three points, valid everywhere
      polyline: '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
    },
    marker: 'bp-route__map',
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

  it('renders a text leaf keyed by legacy `text` — canonical `value` wins', () => {
    // 2026-08-23: raw mutate writers persisted papers whose text leaves were
    // keyed {"type":"text","text":…}; Hollow counts both spellings as content,
    // so those papers passed every write seam and then rendered as structure
    // with zero prose. Twins: inline.ex compose_inline, pdrender inline.go
    // attrStrFirst(n, "value", "text").
    const legacy = renderPortableDocument([
      { type: 'paragraph', content: [{ type: 'text', text: 'legacy prose' }] } as unknown as Block,
    ])
    expect(legacy).toContain('legacy prose')

    const both = renderPortableDocument([
      {
        type: 'paragraph',
        content: [{ type: 'text', value: 'canonical', text: 'stale' }],
      } as unknown as Block,
    ])
    expect(both).toContain('canonical')
    expect(both).not.toContain('stale')
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

  it('covers EXACTLY the registered types (registry ≡ authored cases)', () => {
    const authored = CASES.map((c) => c.type).sort()
    const registered = [...REGISTERED_TYPES].sort()
    expect(authored).toEqual(registered)
    // scaffy:add-block-type Diff MARK:js-count-diff
    // scaffy:add-block-type Filetree MARK:js-count-filetree
    // scaffy:add-block-type Blockquote MARK:js-count-blockquote
    // 49 canonical/aliased emitters from the scaffy census + 6 authoring-drift
    // aliases (bulletList / bullet_list / bulleted-list / bulleted_list /
    // numbered_list / quote) added by pbw-w1 = 55, + the 4 h-tag/ordered-list
    // drift aliases (h1 / h2 / h3 / ordered-list) added by charter D57.
    // scaffy:add-block-type Toc MARK:js-count-toc
    // scaffy:add-block-type Steps MARK:js-count-steps
    // scaffy:add-block-type Footnote MARK:js-count-footnote
    // scaffy:add-block-type Expandable MARK:js-count-expandable
    // scaffy:add-block-type BarChart MARK:js-count-bar-chart
    // scaffy:add-block-type Equation MARK:js-count-equation
    // scaffy:add-block-type CriteriaProgress MARK:js-count-criteria-progress
    // scaffy:add-block-type Video MARK:js-count-video
    // scaffy:add-block-type ApiEndpoint MARK:js-count-api-endpoint
    // scaffy:add-block-type CodeTabs MARK:js-count-code-tabs
    // scaffy:add-block-type Tabs MARK:js-count-tabs
    // + 1: field-number (B085) React emitter (pbw-fix-field-number-react).
    expect(registered).toHaveLength(74)
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

  it('api-endpoint method never breaks out of the class attribute (XSS, fully-live surface)', () => {
    // FULLY-LIVE surface: this emitter string is injected via
    // dangerouslySetInnerHTML with no CSP and no sanitizer. The method-class
    // modifier was raw `--${method.toLowerCase()}`; a quote+tag payload broke
    // out of the class attribute into a live <img>. The fail-closed
    // [a-z0-9-] slug neutralizes it. REDS if the slug fix is reverted.
    const html = renderPortableDocument([
      {
        type: 'api-endpoint',
        method: '"><img src=x onerror=alert(1)>',
        path: '/x',
      },
    ])
    // No attribute breakout — nothing escapes the class="…" quotes.
    expect(html).not.toContain('"><img')
    expect(html).not.toContain('<img')
    expect(html).not.toContain('<script')
    expect(html).not.toContain('onerror=')
    // The badge text is HTML-escaped, not dropped (method is upper-cased first).
    expect(html).toContain('&quot;&gt;&lt;IMG SRC=X ONERROR=ALERT(1)&gt;')
    // The modifier slug keeps only [a-z0-9-] — no stray quote/angle bracket.
    expect(html).toContain('bp-api-endpoint__method bp-api-endpoint__method--imgsrcxonerroralert1')
  })

  it('api-endpoint legit methods keep their byte-identical method--<m> class', () => {
    for (const m of ['GET', 'POST', 'PUT', 'PATCH', 'DELETE']) {
      const html = renderPortableDocument([{ type: 'api-endpoint', method: m, path: '/x' }])
      expect(html).toContain(
        `<span class="bp-api-endpoint__method bp-api-endpoint__method--${m.toLowerCase()}">${m}</span>`,
      )
    }
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

    it('renders object-wrapped table rows/cells and promotes a legacy header row', () => {
      const html = renderPortableDocument([
        {
          type: 'table',
          rows: [
            {
              header: true,
              cells: [{ content: [{ type: 'text', value: 'Name' }] }],
            },
            {
              cells: [{ content: [{ type: 'text', value: 'Ada' }] }],
            },
          ],
        },
      ])
      expect(html).toContain('<th class="bp-table__th"><span>Name</span></th>')
      expect(html).toContain('<td class="bp-table__td"><span>Ada</span></td>')
    })

    it('renders declared record rows in column order', () => {
      const html = renderPortableDocument([
        {
          type: 'table',
          columns: [
            { key: 'k', label: 'Key' },
            { key: 'why', label: 'Why' },
          ],
          rows: [{ why: 'Because', k: 'A' }],
        },
      ])
      expect(html).toContain('<th class="bp-table__th"><span>Key</span></th>')
      expect(html).toContain('<td class="bp-table__td"><span>A</span></td>')
      expect(html).toContain('<td class="bp-table__td"><span>Because</span></td>')
    })

    it('renders legacy text-wrapped columns and cells instead of empty shells', () => {
      const html = renderPortableDocument([
        {
          type: 'table',
          columns: [{ text: 'Surface' }, { text: 'Proof' }],
          rows: [[{ text: 'CLI' }, { text: 'visible' }]],
        },
      ])
      expect(html).toContain('<th class="bp-table__th"><span>Surface</span></th>')
      expect(html).toContain('<td class="bp-table__td"><span>CLI</span></td>')
      expect(html).toContain('<td class="bp-table__td"><span>visible</span></td>')
    })

    it('heatmap normalizes --i by the grid max, not a 1.0 floor (data_viz heat_grid_html)', () => {
      // cells max 0.9 → 0.9/0.9 = 1.000 for the top cell, 0.1/0.9 = 0.111 for the low.
      const html = renderPortableDocument([{ type: 'heatmap', cells: [[0.1, 0.9]] }])
      expect(html).toContain('style="--i:1.000"')
      expect(html).toContain('style="--i:0.111"')
    })

    it('heading composes a content[] inline array, not just bare text (compose.ex heading twin)', () => {
      // The capstone's 16/16 headings persist the `content[]` shape compose.ex
      // already composes; reading `text` alone rendered an empty `<h2></h2>`.
      const html = renderPortableDocument([
        {
          type: 'heading',
          level: 2,
          content: [
            { type: 'text', value: 'The ' },
            { type: 'text', value: 'Operator', marks: ['strong'] },
            { type: 'text', value: "'s Leash" },
          ],
        },
      ])
      expect(html).toContain('<h2>The <span style="font-weight:bold">Operator</span>&#39;s Leash</h2>')
      expect(html).not.toContain('<h2></h2>')
    })

    // ── the {content:[…]} shape, pinned per emitter ────────────────────────
    // The heading emitter had this defect (289b46b1a / PR #6009). A live-corpus
    // census on 2026-07-25 (537 published papers, guerrilla production) found
    // the SAME defect in the list emitter — 2,033 of 10,455 published list items
    // rendering as an empty `<li><span></span></li>` — plus three more emitters.
    // These tests exist so the shape cannot come back a third time.
    describe('the {content:[…]} shape renders, per emitter', () => {
      it('list items authored as {content:[…]} maps render their inlines, never an empty <li>', () => {
        // THE dominant live shape: 2,033 of 10,455 published list items.
        const html = renderPortableDocument([
          {
            type: 'list',
            items: [
              {
                content: [
                  { type: 'text', value: 'claim ' },
                  { type: 'text', value: 'atomically', marks: ['strong'] },
                ],
              },
            ],
          },
        ])
        expect(html).toBe(
          '<ul><li><span>claim <span style="font-weight:bold">atomically</span></span></li></ul>',
        )
        expect(html).not.toContain('<li><span></span></li>')
      })

      it('a {text:…} map list item falls back to its bare text (the content||text law)', () => {
        const html = renderPortableDocument([
          { type: 'list', items: [{ text: 'plain & simple' }] },
        ])
        expect(html).toBe('<ul><li><span>plain &amp; simple</span></li></ul>')
      })

      it('numbered_list carries the same map-shape normalization into an <ol>', () => {
        const html = renderPortableDocument([
          { type: 'numbered_list', items: [{ content: [{ type: 'text', value: 'first' }] }] },
        ])
        expect(html).toBe('<ol><li><span>first</span></li></ol>')
      })

      it('the array / JSON-string / plain-string item shapes are unchanged by the map arm', () => {
        const html = renderPortableDocument([
          {
            type: 'list',
            items: [
              [{ type: 'text', value: 'array' }],
              '[{"type":"text","value":"json"}]',
              'plain',
            ],
          },
        ])
        expect(html).toBe(
          '<ul><li><span>array</span></li><li><span>json</span></li><li><span>plain</span></li></ul>',
        )
      })

      it('eyebrow composes a content[] inline array, not just bare text', () => {
        const html = renderPortableDocument([
          { type: 'eyebrow', content: [{ type: 'text', value: 'Wire / implementation contract' }] },
        ])
        expect(html).toContain('<p class="bp-role-eyebrow">Wire / implementation contract</p>')
        expect(html).not.toContain('<p class="bp-role-eyebrow"></p>')
      })

      it('note composes a content[] inline array in its body, not just bare text', () => {
        const html = renderPortableDocument([
          { type: 'note', label: 'Ledger', content: [{ type: 'text', value: 'epic promoted' }] },
        ])
        expect(html).toContain('<div class="bp-note__d">epic promoted</div>')
        expect(html).not.toContain('<div class="bp-note__d"></div>')
      })

      it('a nested inline array renders as a <span>, matching inline.ex compose_inline(is_list)', () => {
        // `content: [[{…}]]` — flattened one level too shallow. Elixir wraps it
        // in a PdText (walk.ex text/3 → a bare <span>); js dropped it to ''.
        const html = renderPortableDocument([
          { type: 'paragraph', content: [[{ type: 'text', value: 'one level too shallow' }]] },
        ])
        expect(html).toBe('<p><span>one level too shallow</span></p>')
        expect(html).not.toBe('<p></p>')
      })

      it('a list block whose items are nested inline arrays keeps its text', () => {
        const html = renderPortableDocument([
          { type: 'list', items: [[[{ type: 'text', value: 'nested' }]]] },
        ])
        expect(html).toBe('<ul><li><span><span>nested</span></span></li></ul>')
      })

      it('an inline code node authored with children[] renders its text, never <code></code>', () => {
        const html = renderPortableDocument([
          {
            type: 'paragraph',
            content: [{ type: 'code', children: [{ type: 'text', value: 'POST /v1/tasks' }] }],
          },
        ])
        expect(html).toBe('<p><code>POST /v1/tasks</code></p>')
        expect(html).not.toContain('<code></code>')
      })

      it('an inline code node still prefers a flat value when both are present', () => {
        const html = renderPortableDocument([
          {
            type: 'paragraph',
            content: [{ type: 'code', value: 'flat', children: [{ type: 'text', value: 'kids' }] }],
          },
        ])
        expect(html).toBe('<p><code>flat</code></p>')
      })

      it('inline code children are folded to ESCAPED text, never nested markup', () => {
        const html = renderPortableDocument([
          {
            type: 'paragraph',
            content: [
              {
                type: 'code',
                children: [{ type: 'text', value: '<a & b>', marks: ['strong'] }],
              },
            ],
          },
        ])
        expect(html).toBe('<p><code>&lt;a &amp; b&gt;</code></p>')
        expect(html).not.toContain('font-weight:bold')
      })
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

    // `poster` — the block's optional resting frame. Twin of
    // Figures.asciicast_html/4; the pd-golden fixture freezes the SET leg's
    // bytes, these pin the UNSET leg and the escaping.
    it('an asciicast poster rides data-cast-poster, between src and style', () => {
      const html = renderPortableDocument([
        { type: 'asciicast', src: 'https://ex.com/c.cast', caption: 'rec', poster: 'npt:0:12' },
      ])
      expect(html).toContain(
        'data-cast-src="https://ex.com/c.cast" data-cast-poster="npt:0:12" style=',
      )
    })

    it('an unset / blank poster emits NO attribute (client keeps npt:0:1)', () => {
      const unset = renderPortableDocument([{ type: 'asciicast', src: 'https://ex.com/c.cast' }])
      expect(unset).not.toContain('data-cast-poster')
      const blank = renderPortableDocument([
        { type: 'asciicast', src: 'https://ex.com/c.cast', poster: '   ' },
      ])
      expect(blank).not.toContain('data-cast-poster')
    })

    it('a poster is attribute-escaped, never a mount-point breakout', () => {
      const html = renderPortableDocument([
        { type: 'asciicast', src: 'https://ex.com/c.cast', poster: 'npt:0:1" onerror="x' },
      ])
      expect(html).not.toContain('onerror="x')
      expect(html).toContain('&quot;')
    })
  })

  // Reader-Owned Spacing Doctrine (/papers/mechanical-spacing-doctrine, flipped
  // 2026-07-31): a published reader emits only visible semantic groups — an
  // empty paragraph scaffold renders NOTHING (no element), never `<p></p>`.
  // Suppression is exact and narrow (invariant 4): authored text, marks, and
  // non-text inlines stay byte-faithful.
  describe('reader-owned spacing — empty paragraph scaffolds render nothing', () => {
    it('an exact empty paragraph (no content, no text) emits NO element', () => {
      expect(renderPortableDocument([{ type: 'paragraph' }])).toBe('')
      expect(renderPortableDocument([{ type: 'paragraph', content: [] }])).toBe('')
      expect(renderPortableDocument([{ type: 'paragraph', content: [], text: '' }])).toBe('')
    })

    it('a whitespace-only paragraph is scaffold, not layout — emits NO element', () => {
      expect(renderPortableDocument([{ type: 'paragraph', text: '   ' }])).toBe('')
      expect(
        renderPortableDocument([{ type: 'paragraph', content: [{ type: 'text', value: ' \n\t ' }] }]),
      ).toBe('')
      expect(
        renderPortableDocument([{ type: 'paragraph', content: ['  ', { type: 'text', value: ' ' }] }]),
      ).toBe('')
    })

    it('skipped scaffolds add no gap between the remaining semantic blocks (invariant 3)', () => {
      const withScaffolds = renderPortableDocument([
        { type: 'paragraph', text: 'One.' },
        { type: 'paragraph', content: [] },
        { type: 'paragraph', content: [] },
        { type: 'paragraph', text: 'Two.' },
      ])
      const withoutScaffolds = renderPortableDocument([
        { type: 'paragraph', text: 'One.' },
        { type: 'paragraph', text: 'Two.' },
      ])
      expect(withScaffolds).toBe(withoutScaffolds)
      expect(withScaffolds).toBe('<p>One.</p><p>Two.</p>')
    })

    it('suppression is exact and narrow (invariant 4): non-text inlines and marked runs keep their <p>', () => {
      // A non-text inline node is authored content even with no visible text.
      expect(
        renderPortableDocument([
          { type: 'paragraph', content: [{ type: 'tag', name: 'doctrine' }] },
        ]),
      ).not.toBe('')
      // A marked run is authored content — never second-guessed.
      expect(
        renderPortableDocument([
          { type: 'paragraph', content: [{ type: 'text', value: ' ', marks: [{ type: 'bold' }] }] },
        ]),
      ).not.toBe('')
      // Non-empty prose is byte-faithful — same output as before the doctrine flip.
      expect(
        renderPortableDocument([
          { type: 'paragraph', content: [{ type: 'text', value: 'Store meaning; render rhythm.' }] },
        ]),
      ).toBe('<p>Store meaning; render rhythm.</p>')
    })

    it('role paragraphs (ingress/pullquote/eyebrow) are untouched by the sweep', () => {
      // Narrow by design: only the plain `paragraph` scaffold shape is the
      // Enter,Enter artifact; role blocks are deliberate authored structure.
      expect(renderPortableDocument([{ type: 'ingress', content: [] }])).toBe(
        '<p class="bp-role-ingress"></p>',
      )
    })
  })
})

// field-number (B085) — the React leg of the cross-surface fields row
// (pbw-fix-field-number-react). Twin semantics pinned against compose.ex
// field_number_text/1 and internal/pdrender/fields.go fieldNumberRenderer:
// formatted value + optional unit, honest "—" empty state, never the
// bp-unknown-block degrade.
describe('field-number block (B085)', () => {
  it('renders label, value and unit in the bp-field definition row — NOT "Unsupported block"', () => {
    const html = renderPortableDocument([
      { type: 'field-number', label: 'Price', value: 19.99, unit: 'NOK' },
    ])
    expect(html).toContain(
      '<div class="bp-field"><span class="bp-field__l">Price</span><div class="bp-field__v"><span>19.99 NOK</span></div></div>',
    )
    expect(html).not.toContain('Unsupported block')
    expect(html).not.toContain('bp-unknown-block')
  })

  it('an integer value renders without a decimal point (5, never 5.0)', () => {
    const html = renderPortableDocument([{ type: 'field-number', label: 'Count', value: 5 }])
    expect(html).toContain('<span>5</span>')
  })

  it('a whole float renders as its integer (Float.round parity with compose.ex)', () => {
    const html = renderPortableDocument([{ type: 'field-number', label: 'Qty', value: 5.0 }])
    expect(html).toContain('<span>5</span>')
  })

  it('a fully-numeric string value coerces; unit-less values carry no trailing space', () => {
    const html = renderPortableDocument([{ type: 'field-number', label: 'W', value: '2.5' }])
    expect(html).toContain('<span>2.5</span>')
  })

  it('absent and uncoercible values render the honest "—" empty state with NO unit suffix', () => {
    for (const block of [
      { type: 'field-number', label: 'Weight' },
      { type: 'field-number', label: 'Weight', value: 'abc', unit: 'kg' },
      { type: 'field-number', label: 'Weight', value: '12kg', unit: 'kg' },
      { type: 'field-number', label: 'Weight', value: null, unit: 'kg' },
    ] as const) {
      const html = renderPortableDocument([block as unknown as Block])
      expect(html).toContain('<div class="bp-field__v"><span>—</span></div>')
      expect(html).not.toContain('— kg')
      expect(html).not.toContain('Unsupported block')
    }
  })

  it('escapes hostile label and unit strings (no markup injection)', () => {
    const html = renderPortableDocument([
      {
        type: 'field-number',
        label: '<script>x</script>',
        value: 1,
        unit: '<img src=x onerror=alert(1)>',
      },
    ])
    expect(html).toContain('&lt;script&gt;')
    expect(html).not.toContain('<script>')
    expect(html).not.toContain('<img')
    expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;')
  })

  it('genuinely-unknown field types still degrade to bp-unknown-block (fallback NOT weakened)', () => {
    const html = renderPortableDocument([{ type: 'field-molarity', label: 'M', value: 1 }])
    expect(html).toContain('bp-unknown-block')
    expect(html).toContain('Unsupported block: field-molarity')
  })
})
