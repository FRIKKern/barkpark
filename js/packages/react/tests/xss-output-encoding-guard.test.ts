// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// XSS OUTPUT-ENCODING REGRESSION GUARD — the durable carrier of the wave-5 clean
// verdict (pd-block-wishlist-react-xss-2026-08-18). renderPortableDocument returns
// the exact HTML string consumers inject via dangerouslySetInnerHTML with NO CSP
// and NO sanitizer the library controls (PortableDoc.tsx:46/55). So the string
// boundary IS the security boundary: any block emitter that interpolated a raw
// user field into a class token, an attribute value, a URL sink, or element
// markup would be a fully-live XSS. The verify fleet run-proved every React
// emitter neutralizes breakout payloads there (the sole prior live sink,
// api-endpoint's method class, was fixed in #12275 and is covered by
// PortableDoc.test.tsx:617 — SKIPPED here). This guard drives a breakout payload
// through EVERY emitter family at that boundary and locks the encoding in: it goes
// RED the moment an escaper is removed or a future emitter interpolates a raw
// user field.
//
// ── MUTATION-VALIDITY (proves this guard is not vacuous green) ─────────────────
// Neuter both escapers in src/inline.tsx — escapeHtml → `return String(s)` and
// safeUrl → `return typeof href === 'string' ? href : '#'` (raw passthrough),
// re-run THIS file, restore, re-run:
//
//   escapers intact  (baseline)  → 68 passed,  0 failed  (GREEN)
//   escapeHtml + safeUrl neutered → 64 failed,  4 passed  (RED)
//   escapers restored            → 68 passed,  0 failed  (GREEN)
//
// A guard that stays green with the escapers neutered would be vacuous; this one
// flips 64 of its 68 assertions the moment the escapers are removed. The 4 that
// stay green are genuine NON-sinks with no raw-markup path (chat-thinking, whose
// only field is a numeric token count; equation, whose tokenizer splits `<`/`>`
// into separate <mo> atoms so no contiguous `<tag` can form; status-legend, which
// takes no user input; and the positive safe-URL case), so they cannot flip —
// which is the honest result, not a gap.
//
// The assertions avoid the V4 false-positive: they NEVER match the bare escaped
// payload text (`&lt;img … onerror=alert(1)&gt;` still contains the substrings
// `onerror=alert(1)` and `src=x`, which are harmless once the angle brackets are
// entities). They match only a REAL tag opening (a literal `<`) or a REAL live
// URL scheme inside a quoted url attribute — the actual breakout signatures.

import { describe, it, expect } from 'vitest'
import { renderPortableDocument, type Block } from '../src'

// The text/attr/class breakout payload — one string exercising every tag-opening
// signature the assertions look for (`<img src=x`, `<svg onload`, `<script`,
// `<iframe`). Dropped into every user-controlled text, attribute, and class field.
const X =
  '"><img src=x onerror=alert(1)><svg onload=alert(2)><script>alert(3)</script><iframe src=javascript:alert(4)>'
// The URL-sink payload — dropped into every href/src/poster/track URL field.
const JS = 'javascript:alert(1)'

// A real breakout leaves a LITERAL `<tag` in the string; the escaped payload only
// ever carries `&lt;img`/`&lt;svg`/… (no literal `<`). These four signatures are
// the attacker's tags specifically — `<img src=x` (the payload's img, never the
// legit image emitter's `<img src="#"`), `<svg onload` (never chart/spark's
// `<svg viewBox`/`<svg class`), and `<script`/`<iframe` which no emitter emits.
function assertNoBreakout(html: string, opts: { allowImgSvg?: boolean } = {}): void {
  expect(html).not.toContain('<img src=x') // attacker <img>, not the legit src="#"
  expect(html).not.toContain('<svg onload') // attacker <svg>, not chart/spark svg
  expect(html).not.toContain('<script') // no emitter emits a script tag
  expect(html).not.toContain('<iframe') // no emitter emits an iframe tag
  // No live URL scheme survived into an href/src/poster attribute value. safeUrl
  // rewrites javascript:/data:/vbscript: (and protocol-relative) to `#`.
  expect(html).not.toMatch(/(?:\bhref|\bsrc|\bposter)="\s*(?:javascript|data|vbscript):/i)
  // Blocks that do NOT legitimately emit an <img>/<svg> get the stricter check:
  // ANY such tag opening is a breakout. Skipped for image/chart/stat/stats/video,
  // which legitimately emit those tags (their attacker-signature checks above
  // still catch a real break-out).
  if (!opts.allowImgSvg) {
    expect(html).not.toMatch(/<(?:img|svg|script|iframe)\b/i)
  }
}

// One hostile-data block per emitter behaviour, each authored to render PAST the
// empty-guard early-returns (the value-bearing fields are non-empty), with the
// breakout payload in every user text/attr/class field and `javascript:` in every
// URL sink. `allowImgSvg` marks the emitters that legitimately emit <img>/<svg>.
interface HostileCase {
  name: string
  block: Block
  allowImgSvg?: boolean
}

const para = (v: string): Block => ({ type: 'paragraph', content: [{ type: 'text', value: v }] })

const CASES: HostileCase[] = [
  // ── core: prose + inline marks ─────────────────────────────────────────────
  { name: 'heading', block: { type: 'heading', level: 2, text: X } },
  { name: 'h1/h2/h3 alias', block: { type: 'h3', text: X } },
  { name: 'eyebrow', block: { type: 'eyebrow', text: X } },
  { name: 'byline', block: { type: 'byline', items: [X, X] } },
  { name: 'ingress', block: { type: 'ingress', content: [{ type: 'text', value: X }] } },
  { name: 'paragraph', block: para(X) },
  { name: 'pullquote', block: { type: 'pullquote', content: [{ type: 'text', value: X }] } },
  {
    name: 'paragraph link mark (javascript href)',
    block: {
      type: 'paragraph',
      content: [{ type: 'text', value: X, marks: [{ type: 'link', href: JS }] }],
    },
  },
  {
    name: 'blockquote',
    block: { type: 'blockquote', content: [{ type: 'text', value: X }], cite: X },
  },
  { name: 'list', block: { type: 'list', ordered: false, items: [[{ type: 'text', value: X }]] } },
  { name: 'ordered-list', block: { type: 'ordered-list', items: [{ content: [{ type: 'text', value: X }] }] } },
  // ── core: action + media ───────────────────────────────────────────────────
  { name: 'action (javascript href)', block: { type: 'action', href: JS, label: X, priority: X } },
  {
    name: 'image (javascript src + payload alt/dims)',
    block: { type: 'image', src: JS, alt: X, width: X, height: X },
    allowImgSvg: true,
  },
  {
    name: 'figure (payload caption + child)',
    block: { type: 'figure', caption: 'Figure 1. ' + X, child: para(X) },
  },
  {
    name: 'video (javascript src/poster + payload track)',
    block: {
      type: 'video',
      src: JS,
      poster: JS,
      captions: [{ lang: X, src: JS }],
    },
    allowImgSvg: true, // emits a <video> (not flagged) but treat leniently
  },
  {
    // asciicast poster is a TIMESTAMP (data-cast-poster, attribute-escaped, NOT a
    // URL sink per core.ts) — so it carries the text payload, not javascript:.
    name: 'asciicast (javascript src + payload poster/caption)',
    block: { type: 'asciicast', src: JS, caption: X, poster: X },
  },
  { name: 'diagram (mermaid source + caption)', block: { type: 'diagram', source: X, caption: 'Figure 2. ' + X } },
  // ── core: containers + code ────────────────────────────────────────────────
  { name: 'toc (payload text + anchor)', block: { type: 'toc', items: [{ text: X, level: 2, anchor: X }] } },
  {
    name: 'callout plain',
    block: { type: 'callout', tone: X, title: X, content: [{ type: 'text', value: X }] },
  },
  {
    name: 'callout collapsible',
    block: { type: 'callout', collapsible: true, title: X, content: [{ type: 'text', value: X }] },
  },
  {
    name: 'expandable',
    block: { type: 'expandable', summary: X, open: true, blocks: [para(X)] },
  },
  { name: 'filetree', block: { type: 'filetree', text: X, legend: X } },
  {
    name: 'section grid',
    block: { type: 'section', title: X, layout: { mode: 'grid', tracks: 2, gap: 'md' }, blocks: [para(X)] },
  },
  {
    name: 'columns',
    block: { type: 'columns', columns: [[para(X)]] },
  },
  {
    name: 'terminal',
    block: { type: 'terminal', title: X, live: true, footer: X, children: [para(X)] },
  },
  { name: 'code', block: { type: 'code', value: X } },
  {
    name: 'code-tabs',
    block: { type: 'code-tabs', syncKey: X, tabs: [{ label: X, language: X, value: X }] },
  },
  {
    name: 'tabs',
    block: { type: 'tabs', tabs: [{ label: X, blocks: [para(X)] }] },
  },
  { name: 'footnote (payload id + text)', block: { type: 'footnote', notes: [{ id: X, text: X }] } },
  {
    name: 'steps',
    block: { type: 'steps', steps: [{ title: X, blocks: [para(X)] }] },
  },
  { name: 'diff (file/lang/diff)', block: { type: 'diff', file: X, lang: X, diff: '+' + X + '\n-' + X } },
  // ── core: task-tracking / composition ──────────────────────────────────────
  { name: 'notes', block: { type: 'notes', items: [{ label: X, lead: X, text: X }] } },
  { name: 'note', block: { type: 'note', label: X, lead: X, text: X } },
  { name: 'cards', block: { type: 'cards', items: [{ title: X, text: X, tone: X }] } },
  {
    name: 'card',
    block: { type: 'card', tone: X, slots: { title: [{ type: 'heading', level: 3, text: X }] } },
  },
  { name: 'pipeline', block: { type: 'pipeline', nodes: [{ kind: X, title: X, detail: X, files: X, source: X }] } },
  { name: 'stage', block: { type: 'stage', kind: X, title: X, detail: X, files: X } },
  {
    name: 'task-detail',
    block: {
      type: 'task-detail',
      task: {
        title: X,
        status: 'in_progress',
        priority: X,
        kind: X,
        worker: X,
        description: X,
        criteria: [{ text: X, met: true, evidence: X }],
        papers: [X],
        labels: [X],
      },
    },
  },
  {
    name: 'roadmap',
    block: { type: 'roadmap', snapshot: [{ title: X, status: 'done', left: 0, width: 50 }], scale: [X, X], today: 30 },
  },
  { name: 'status-legend', block: { type: 'status-legend' } },
  // ── dataviz ────────────────────────────────────────────────────────────────
  {
    name: 'stat',
    block: { type: 'stat', value: X, label: X, denom: X, unit: X, body: X, source: X, spark: [1, 2, 3], max: 100 },
    allowImgSvg: true, // emits a spark <svg>
  },
  {
    name: 'stats',
    block: { type: 'stats', items: [{ value: X, label: X, source: X }], sourceDefault: X },
    allowImgSvg: true,
  },
  {
    name: 'stat-grid',
    block: { type: 'stat-grid', items: [{ value: X, label: X }] },
    allowImgSvg: true,
  },
  {
    name: 'chart',
    block: {
      type: 'chart',
      series: [{ label: X, points: [1, 2, 3] }],
      axes: { xLabels: [X, X], min: X, max: X },
      caption: X,
      kind: X,
    },
    allowImgSvg: true, // emits the chart <svg>
  },
  { name: 'bar-chart', block: { type: 'bar-chart', bars: [{ label: X, value: 5 }], values: true } },
  { name: 'gauge-list', block: { type: 'gauge-list', title: X, rows: [{ label: X, value: 2, note: X }] } },
  {
    name: 'duel',
    block: {
      type: 'duel',
      legendA: X,
      legendB: X,
      rows: [{ label: X, delta: X, valueA: X, valueB: X, unit: X, source: X }],
    },
  },
  {
    name: 'lineage',
    block: {
      type: 'lineage',
      sourceDefault: X,
      nodes: [{ overline: X, title: X, value: X, unit: X, body: X, source: X }],
    },
  },
  {
    name: 'heatmap grid',
    block: { type: 'heatmap', cells: [[1, 2], [3, 4]], rowLabels: [X, X], colLabels: [X, X] },
  },
  {
    name: 'heatmap calendar',
    block: { type: 'heatmap', mode: 'calendar', cells: [[1, 2], [3, 4]], rowLabels: [X], colLabels: [X] },
  },
  {
    name: 'heatmap matrix',
    block: { type: 'heatmap', cells: [[1, 2], [3, 4]], values: true, marginals: true, rowLabels: [X], colLabels: [X] },
  },
  { name: 'criteria-progress', block: { type: 'criteria-progress', rows: [{ label: X, met: 2, total: 5 }] } },
  // ── chat ───────────────────────────────────────────────────────────────────
  { name: 'chat-approval', block: { type: 'chat-approval', tool_name: X, summary: X, approval_status: 'pending' } },
  { name: 'chat-plan', block: { type: 'chat-plan', title: X, preview: X, approval_status: 'pending' } },
  {
    name: 'chat-question',
    block: { type: 'chat-question', questions: [{ question: X, options: [X, X] }], approval_status: 'pending' },
  },
  {
    name: 'chat-todo/transcript',
    block: { type: 'chat-todo', todos: [{ content: X, status: 'in_progress', active_form: X }] },
  },
  { name: 'chat-thinking', block: { type: 'chat-thinking', tokens: 1500 } },
  {
    name: 'chat-tool-diff',
    block: { type: 'chat-tool-diff', input: { file_path: X, old_string: X, new_string: X + '\nchanged' } },
  },
  // ── forms ──────────────────────────────────────────────────────────────────
  {
    name: 'form',
    block: {
      type: 'form',
      kind: X,
      questions: [
        { id: X, prompt: X, type: X, options: [X], rationale: X, recommendation: X },
        { id: X, prompt: X, type: 'single', options: [X, X] },
      ],
    },
  },
  {
    name: 'questionnaire',
    block: { type: 'questionnaire', questions: [{ id: X, prompt: X, type: 'scale', scale: { min: 1, max: 5 } }] },
  },
  // ── math ───────────────────────────────────────────────────────────────────
  { name: 'equation', block: { type: 'equation', tex: X, display: true } },
  // ── table ──────────────────────────────────────────────────────────────────
  {
    name: 'table (payload cells + javascript link cell)',
    block: {
      type: 'table',
      head: [[{ type: 'text', value: X }]],
      rows: [
        [[{ type: 'text', value: X }]],
        [[{ type: 'text', value: X, marks: [{ type: 'link', href: JS }] }]],
      ],
    },
  },
  // ── sheet (URL cell + bg/style/colwidth/merge injection attempts) ───────────
  {
    name: 'sheet',
    block: {
      type: 'sheet',
      snapshot: {
        head: [X, 'https://evil.example/"><img src=x>'],
        rows: [
          [X, JS],
          ['https://ok.example/a', X],
        ],
        col_widths: [X, 100],
        styles: {
          '0,0': { b: true, i: true, bg: X, al: X },
          '1,0': { bg: '#abcdef;background:url(javascript:alert(1))', al: 'right' },
        },
        merges: [[0, 0, 1, 1]],
      },
    },
  },
  // ── taskboard ──────────────────────────────────────────────────────────────
  {
    name: 'task-board',
    block: {
      type: 'task-board',
      snapshot: [{ title: X, status: 'in_progress', priority: X, criteria: { met: 2, total: 5 } }],
    },
  },
  {
    name: 'tasks',
    block: {
      type: 'tasks',
      title: X,
      snapshot: [{ title: X, status: 'ready', phase: X, worker: X, blocked_by: X, priority: X }],
    },
  },
  { name: 'task-list', block: { type: 'task-list', snapshot: [{ title: X, status: 'open' }] } },
]

describe('React SDK XSS output-encoding regression guard', () => {
  it.each(CASES)('$name neutralizes the breakout payload at the string boundary', ({ block, allowImgSvg }) => {
    const html = renderPortableDocument([block])
    // Sanity: the case actually rendered past the empty-guard early-returns.
    expect(html.length).toBeGreaterThan(0)
    // `allowImgSvg` is optional on CASES, so destructuring yields `boolean | undefined`.
    // Under `exactOptionalPropertyTypes` an optional property must be ABSENT, not
    // present-and-undefined, so omit the key entirely when it was not set. The sole
    // read is `if (!opts.allowImgSvg)`, so absent and `false` are already equivalent.
    assertNoBreakout(html, allowImgSvg === undefined ? {} : { allowImgSvg })
  })

  it('renders the whole hostile document in one pass with no breakout', () => {
    const html = renderPortableDocument(CASES.map((c) => c.block))
    // The combined document legitimately contains <img> (image) and <svg> (chart,
    // spark), so only the attacker-signature + URL-scheme checks apply here.
    expect(html).not.toContain('<img src=x')
    expect(html).not.toContain('<svg onload')
    expect(html).not.toContain('<script')
    expect(html).not.toContain('<iframe')
    expect(html).not.toMatch(/(?:\bhref|\bsrc|\bposter)="\s*(?:javascript|data|vbscript):/i)
    // Positive: the payload really did flow through and get HTML-escaped somewhere
    // (proves the emitters processed it, not silently dropped it).
    expect(html).toContain('&lt;img src=x')
  })

  it('safe URLs still render — the scheme allowlist is not over-broad', () => {
    // A legit https link keeps its href (the guard rejects schemes, not all URLs).
    const html = renderPortableDocument([{ type: 'action', href: 'https://ok.example/go', label: 'Go' }])
    expect(html).toContain('href="https://ok.example/go"')
  })
})
