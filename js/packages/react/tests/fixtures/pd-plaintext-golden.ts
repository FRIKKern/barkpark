// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// JS-OWNED per-type plain-text golden map for `toPlainText` over the 46-type
// PortableDocument grammar.
//
// There is NO per-type plain-text source of truth anywhere else in the repo — Go
// pdrender, the JS SDK, and Elixir `preview.ex` all lack a per-block extractor
// (preview.ex reads only paragraph/ingress/title-role), and every one of the 42
// frozen `pd-golden/*.golden.json` `.input` blocks returns `''` from the legacy
// Sanity-shaped `toPlainText`. So THIS map is the contract: each string is the
// exact plain text `toPlainText([golden.input])` must produce for that type,
// derived from the SAME frozen `pd-golden` fixtures (never re-authoring them).
//
// Every grammar type appears in exactly one of the two maps below.
// appears in EXACTLY ONE of the two maps below; the test fails if any golden
// type is in neither (silent-drop ≠ intentional-skip) or in both.

/**
 * PROSE-bearing types → the exact expected plain text.
 *
 * Each is asserted non-empty AND exactly equal to this string. Because each type
 * has its own dispatch clause in `blockText`, reverting a clause flips its output
 * to `''`, which no longer equals the non-empty golden → the test goes red
 * (anti-vacuous-green). Reading order + `\n\n` block joins mirror the renderer.
 */
export const PROSE_GOLDEN: Record<string, string> = {
  // headings / roles
  heading: 'The render path',
  eyebrow: 'Dispatches',
  byline: 'Jane Rae · 2026-07-16',
  // prose runs (marks contribute no text)
  paragraph: 'A body paragraph with bold emphasis inside it.',
  ingress: 'A lead paragraph that opens the article.',
  pullquote: 'The best interface is no interface.',
  blockquote: 'The best way to predict the future is to invent it.\n\nAlan Kay',
  list: 'First point\nSecond point',
  callout: 'Heads up\n\nThis is a warning callout body.',
  code: 'def hello do\n  :world\nend',
  // annotation rows (label + bold run-in lead + body)
  note: 'Note Run-in A single annotated row.',
  notes: 'Upgrade Instant The board updates live.\n\nWhy Trust You always feel progress.',
  // tables (cell inline content, head then rows)
  table: 'Surface Renderer\nPhoenix Elixir\nNext React',
  // containers (recurse into prose descendants)
  figure: 'The figure body.\n\nFigure with a captioned child',
  card: 'Card title\n\nCard body text.',
  cards: 'Rule one\n\nThe first rule body.\n\nRule two\n\nThe second rule body.',
  columns: 'Left column body.\n\nRight column body.',
  section: 'Alpha cell\n\nBeta cell',
  terminal: 'Inside the frame.',
  // grown (pbw-stier-steps): each step's title + its nested blocks' prose
  steps: 'Claim the task\n\nRun bp task next.\n\nStamp evidence',
  // grown (pbw-stier-footnote): each note's text, in order
  footnote: 'The board updates live.\n\nYou always feel progress.',
  // grown (pbw-stier-equation): the tex source is reading content, the `code` precedent
  equation: 'E = mc^2',
  // grown (jarl-dogfood, toPlainText silent-drop sweep): the summary line + the
  // nested blocks' prose — collapsed content is still reading content
  expandable: 'Show the full trace\n\nHidden detail.',
  // code-story blocks (W7 grow: diff reads its verbatim `diff` attr (D75),
  // filetree its verbatim `text` tree lines (D78) — the `code` precedent)
  diff:
    'diff --git a/lib/render/compose.ex b/lib/render/compose.ex\n' +
    'index 3f9c2d1..8a41b7e 100644\n' +
    '--- a/lib/render/compose.ex\n' +
    '+++ b/lib/render/compose.ex\n' +
    '@@ -1,4 +1,5 @@\n' +
    ' defmodule Render.Compose do\n' +
    '-  def compose(block), do: starter(block)\n' +
    '+  def compose(block), do: grown(block)\n' +
    '+  defp grown(block), do: block\n' +
    ' end',
  filetree:
    'api/lib/barkpark/portable_doc/render/\n' +
    '├── components.ex ● diff_html/1 + filetree_html/1\n' +
    '├── compose.ex ○ grew the diff + filetree clauses\n' +
    '└── starter_stub.ex ✕ removed',
  // grown (pbw-stier-tabs): each tab's label + its nested blocks' prose, the
  // `steps` precedent (a tab is a titled panel, same shape as a step)
  tabs: 'macOS\n\nbrew install barkpark\n\nLinux\n\ncurl -fsSL install.sh | sh',
  'paper-links':
    'Continue reading\n\nPapers with useful context for this change.\n\nPaper authoring excellence\n\nA practical guide to publishing clear, useful Papers.\n\nSee the principles behind this example.',
}

/**
 * Intentionally-TEXTLESS types → the rationale each returns `''`.
 *
 * This is the explicit SKIP allow-list. Each type is asserted to return exactly
 * `''`. A type that returns `''` but is NOT listed here fails the coverage test —
 * that is precisely what separates an intentional skip from a silent drop. The
 * rationale strings are the committed justification (families: data-viz / forms /
 * chat / media / structural). Some of these blocks DO carry human-readable
 * strings (an image `alt`, a chart `caption`, a task-board card `title`, a CTA
 * `label`); those are accessibility metadata, viz/chrome labels or live-widget
 * state, NOT reading-flow body prose, so `toPlainText` deliberately omits them.
 */
export const TEXTLESS_SKIP: Record<string, string> = {
  // scaffy:add-block-type CodeTabs MARK:plaintext-skip-code-tabs
  'code-tabs': 'per-language code snippets behind a tab switcher — chrome/UI, no reading-flow prose (same textless family as code/terminal)',
  // scaffy:add-block-type ApiEndpoint MARK:plaintext-skip-api-endpoint
  'api-endpoint': 'structured endpoint card — method/path/params table, no reading-flow prose (same textless family as table/sheet)',
  // scaffy:add-block-type Video MARK:plaintext-skip-video
  'video': 'media embed — a native <video> file, no reading-flow prose (same textless family as image/asciicast)',
  // scaffy:add-block-type CriteriaProgress MARK:plaintext-skip-criteria-progress
  'criteria-progress': 'attrs-derived met/total rollup (labels + numeric fractions) — no reading-flow prose, same textless family as bar-chart/chart/heatmap',
  // scaffy:add-block-type BarChart MARK:plaintext-skip-bar-chart
  'bar-chart': 'attrs-derived categorical counts (labels + numeric values) — no reading-flow prose, same textless family as chart/heatmap',
  // scaffy:add-block-type Expandable MARK:plaintext-skip-expandable
  // (expandable moved to PROSE_GOLDEN — jarl-dogfood silent-drop sweep: its
  // summary + nested blocks ARE reading-flow prose; the marker stays for scaffy.)
  // scaffy:add-block-type Toc MARK:plaintext-skip-toc
  'toc': 'navigation apparatus — its items are anchors DUPLICATING heading text already extracted from the headings themselves; including it would double every heading in excerpts/search',
  // ── structural / interactive ──────────────────────────────────────────────
  divider: 'structural rule — a decorative separator, carries no text',
  action:
    'interactive CTA control — its `label` is button chrome, not reading-flow prose',
  // ── media ─────────────────────────────────────────────────────────────────
  image: 'media embed — `alt` is accessibility metadata, not body prose',
  asciicast: 'media embed (terminal recording) — `caption` is a media label',
  diagram: 'media/diagram (mermaid) — `source` is diagram DSL, `caption` a viz label',
  // ── data-viz ────────────────────────────────────────────────────────────────
  chart: 'data-viz — numeric series + axis labels; `caption` is a viz label',
  route: 'data-viz sport track — the polyline is coordinate data, sport/distance/caption are viz chrome, same textless family as chart/heatmap',
  heatmap: 'data-viz — a numeric cell matrix, no prose',
  stat: 'data-viz metric — `label`/`value` are viz chrome, not prose',
  'stat-grid': 'data-viz metric grid — label/value chrome',
  stats: 'data-viz metric grid (alias of stat-grid) — label/value chrome',
  duel: 'data-viz two-arm comparison (jarl figure family) — legend/value/delta chrome, not prose',
  lineage: 'data-viz dated nodes (jarl figure family) — overline/value chrome; node bodies are figure captions, not reading flow',
  'status-legend': 'data-viz legend — generated glyph/name/meaning chrome, no content',
  pipeline: 'data-viz flow diagram — node titles are diagram labels',
  stage: 'data-viz flow node — kind/title/detail are diagram labels',
  roadmap: 'data-viz timeline — phase titles are viz labels',
  // ── forms ─────────────────────────────────────────────────────────────────
  form: 'interactive form — question prompts are form controls, not article prose',
  questionnaire: 'interactive form (alias of form) — question-prompt controls',
  // ── chat transcript widgets ─────────────────────────────────────────────────
  'chat-thinking': 'chat-transcript widget — a token count, no prose',
  'chat-todo': 'chat-transcript todo widget — live agent-todo state',
  'chat-tool-diff': 'chat-transcript tool-call widget — a code diff payload, not prose',
  // ── interactive chat cards (D35) — read-only VISUAL of an envelope-driven ask ─
  'chat-approval': 'interactive chat card — tool-name/summary + status badge, an approval-ask control',
  'chat-question': 'interactive chat card — AskUserQuestion prompts + option chips, a form control',
  'chat-plan': 'interactive chat card — plan title/preview + status badge, a plan-approval control',
  // ── data-viz meter ──────────────────────────────────────────────────────────
  'gauge-list': 'data-viz meter list — label/digit/note are gauge chrome, not prose',
  // ── data-grid / task widgets ────────────────────────────────────────────────
  sheet: 'spreadsheet-snapshot data grid — a live external-sheet widget, tabular chrome',
  'task-board': 'task-board widget — card titles are live board chrome, not article prose',
  'task-list': 'task-list widget (alias) — live task state chrome',
  tasks: 'task-list widget (alias) — live task state chrome',
  'task-detail': 'task widget — criteria/timeline/labels are live task chrome',
}
