// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Core + task-tracking block emitters — the JS twins of walk.ex / compose.ex /
// figures.ex / components.ex at style=:article. Every function returns an HTML
// string; container blocks recurse through the shared dispatcher.

import {
  type Block,
  escapeHtml,
  escapeAttr,
  safeUrl,
  str,
  num,
  asList,
  isMap,
  renderInlines,
  glyphHtml,
  roleOf,
  labelForRole,
  meaningForRole,
  LEGEND_ROLES,
  textLeafValue,
} from '../inline'
import { renderBlock, renderBlocks } from './registry'
import { CHAT_DIFF_BUDGET, diffRowsHtml, splitLines, type DiffLine } from './chat'

type Emit = (block: Block) => string

/* ── prose core (walk.ex) ─────────────────────────────────────────────────── */

function paragraphInline(b: Block): unknown {
  const content = b.content
  if (Array.isArray(content) && content.length) return content
  const text = str(b.text)
  return text !== '' ? text : []
}

const heading: Emit = (b) => {
  const raw = b.level
  const level =
    raw === 1 || raw === 2 || raw === 3 || raw === '1' || raw === '2' || raw === '3'
      ? Number(raw)
      : 2
  // Dual-shape body, byte-for-byte the compose.ex heading twin (compose_block
  // heading): a non-empty `content` inline array composes through the shared
  // inline dispatcher; otherwise the bare `text` string (escaped). The 16/16
  // capstone headings persist the `content[]` shape — reading `text` alone left
  // them rendering an empty `<h2></h2>`.
  return `<h${level}>${renderInlines(paragraphInline(b))}</h${level}>`
}

// The h1/h2/h3 authoring-drift aliases (charter D57), the JS twin of compose.ex's
// @heading_aliases clause. The level comes from the TYPE, not from `level`: SIX
// of the 18 drifted headings (1 h2 + all 5 h3s) carry no `level` key, so
// `h3: heading` alone would emit `<h2>`. Spreading the level in makes the type
// authoritative — zero live blocks contradict their own type spelling.
const headingAtLevel =
  (level: 1 | 2 | 3): Emit =>
  (b) =>
    heading({ ...b, level } as Block)

// Swept sibling of the heading/list content[] defect: eyebrow read `text` alone,
// so the 3 live eyebrows persisted as `{content:[…]}` rendered an empty
// `<p class="bp-role-eyebrow"></p>`. The `text` path is byte-identical (the
// fallback only fires when `content` is absent/empty), so the golden parity
// fixture is untouched.
const eyebrow: Emit = (b) => `<p class="bp-role-eyebrow">${renderInlines(paragraphInline(b))}</p>`

// scaffy:add-block-type Tabs MARK:js-emitter-tabs
// Mirrors compose_block(tabs) (compose.ex, :article leg): a tab strip
// (role=tablist) + every panel, each panel's `blocks` recursed through the
// shared `renderBlocks` dispatcher (the columns/steps precedent). NO-JS
// DEGRADE = every panel stays visible in this markup — the client.ts /
// bulldocs.html.heex hydration legs add `hidden` to every non-active panel
// post-mount (I1 dual hydration). Empty `tabs` renders nothing.
interface TabEntry {
  label: string
  blocks: Block[]
}

function tabEntries(b: Block): TabEntry[] {
  return asList(b.tabs)
    .filter(isMap)
    .map((t) => ({ label: str(t.label), blocks: asList<Block>(t.blocks) }))
}

const tabs: Emit = (b) => {
  const entries = tabEntries(b)
  if (entries.length === 0) return ''

  const strip = entries
    .map((t, i) => {
      const activeClass = i === 0 ? ' bp-tabs__tab--active' : ''
      return (
        `<button type="button" class="bp-tabs__tab${activeClass}" role="tab" ` +
        `aria-selected="${i === 0}" data-tab-index="${i}">${escapeHtml(t.label)}</button>`
      )
    })
    .join('')

  const panels = entries
    .map((t, i) => `<div class="bp-tabs__panel" data-tab-index="${i}">${renderBlocks(t.blocks)}</div>`)
    .join('')

  return (
    `<div class="bp-tabs"><div class="bp-tabs__strip" role="tablist">${strip}</div>` +
    `<div class="bp-tabs__panels">${panels}</div></div>`
  )
}

// scaffy:add-block-type CodeTabs MARK:js-emitter-code-tabs
// Mirrors compose_block(code-tabs) (compose.ex, :article leg): a tab strip
// (role=tablist) + every panel via the SAME inline-styled markup the `code`
// emitter uses (byte-identical to Figures.code_block_html/1 — see the
// `code` emitter below; codeBlockHtml factors it out so both share one
// literal). NO-JS DEGRADE = every panel stays visible in this markup; the
// client.ts / bulldocs.html.heex hydration legs are what add `hidden` to
// every non-active panel post-mount (I1 dual hydration — this emitter only
// paints the shell). Empty `tabs` renders nothing.
interface CodeTabEntry {
  label: string
  language: string
  value: string
}

function codeTabEntries(b: Block): CodeTabEntry[] {
  return asList(b.tabs)
    .filter(isMap)
    .map((t) => ({
      label: str(t.label),
      language: str(t.language),
      value: str(t.value ?? t.code),
    }))
}

const codeTabs: Emit = (b) => {
  const tabs = codeTabEntries(b)
  if (tabs.length === 0) return ''

  const syncKey = str(b.syncKey)
  const syncAttr = syncKey === '' ? '' : ` data-sync-key="${escapeAttr(syncKey)}"`

  const strip = tabs
    .map((t, i) => {
      const activeClass = i === 0 ? ' bp-code-tabs__tab--active' : ''
      return (
        `<button type="button" class="bp-code-tabs__tab${activeClass}" role="tab" ` +
        `aria-selected="${i === 0}" data-lang="${escapeAttr(t.language)}">` +
        `${escapeHtml(t.label)}</button>`
      )
    })
    .join('')

  const panels = tabs
    .map(
      (t) =>
        `<div class="bp-code-tabs__panel" data-lang="${escapeAttr(t.language)}">${codeBlockHtml(t.value)}</div>`,
    )
    .join('')

  return (
    `<div class="bp-code-tabs"${syncAttr}>` +
    `<div class="bp-code-tabs__strip" role="tablist">${strip}</div>` +
    `<div class="bp-code-tabs__panels">${panels}</div></div>`
  )
}

// scaffy:add-block-type ApiEndpoint MARK:js-emitter-api-endpoint
// Mirrors compose_block(api-endpoint) (compose.ex): a method badge + path
// line, then a params table (name/in/type/required) — byte-identical to
// the Elixir _raw clause. No method and no path is the honest empty state.
function apiEndpointParamRow(param: unknown): string {
  if (!isMap(param)) return ''
  const required = param.required === true || String(param.required).trim().toLowerCase() === 'true'
  return (
    `<tr><td>${escapeHtml(str(param.name))}</td><td>${escapeHtml(str(param.in))}</td>` +
    `<td>${escapeHtml(str(param.type))}</td><td>${required ? 'Yes' : 'No'}</td></tr>`
  )
}

const apiEndpoint: Emit = (b) => {
  const method = str(b.method).toUpperCase()
  const path = str(b.path)
  if (method === '' && path === '') return ''

  // The method-class modifier is a FAIL-CLOSED lowercase [a-z0-9-] slug of the
  // user-controlled method (hyphen kept) — mirrors compose.ex's slug so a value
  // like `"><img src=x onerror=alert(1)>` cannot break out of the class
  // attribute into live markup. An empty slug drops the modifier class entirely.
  const methodSlug = method.toLowerCase().replace(/[^a-z0-9-]/g, '')
  const methodClass =
    methodSlug === ''
      ? 'bp-api-endpoint__method'
      : `bp-api-endpoint__method bp-api-endpoint__method--${methodSlug}`

  const head =
    `<div class="bp-api-endpoint__head">` +
    `<span class="${methodClass}">${escapeHtml(method)}</span>` +
    `<code class="bp-api-endpoint__path">${escapeHtml(path)}</code>` +
    `</div>`

  const params = asList(b.params)
  const paramsHtml =
    params.length === 0
      ? ''
      : `<table class="bp-api-endpoint__params">` +
        `<thead><tr><th>Name</th><th>In</th><th>Type</th><th>Required</th></tr></thead>` +
        `<tbody>${params.map(apiEndpointParamRow).join('')}</tbody></table>`

  return `<div class="bp-api-endpoint">${head}${paramsHtml}</div>`
}

// scaffy:add-block-type Expandable MARK:js-emitter-expandable
// Mirrors compose_block(expandable): starter emit — `text` escaped into
// the bp-expandable wrapper, byte-identical to the Elixir _raw clause.
// Mirrors compose_block(expandable): a generic collapsible container — the
// same native-<details> pattern `callout` ships, minus the callout chrome
// (I0: zero-JS). `open` reflects the block's own state (this emitter only
// ever renders the :article View surface). Empty (no summary, no children)
// renders nothing.
const expandable: Emit = (b) => {
  const summary = str(b.summary)
  const blocks = asList(b.blocks ?? b.children)
  if (summary === '' && blocks.length === 0) return ''

  const inner = renderBlocks(blocks)
  const openAttr = b.open === true ? ' open' : ''
  return `<details${openAttr} class="bp-expandable"><summary>${escapeHtml(summary)}</summary><div class="bp-expandable__body">${inner}</div></details>`
}

// scaffy:add-block-type Footnote MARK:js-emitter-footnote
// Mirrors compose_block(footnote): starter emit — `text` escaped into
// the bp-footnote wrapper, byte-identical to the Elixir _raw clause.
// Mirrors compose_block(footnote): a numbered reference apparatus — `notes` is
// a list of {id, text}. Each shown note carries an `id="fn-<id>"` anchor (the
// backlink target an inline marker elsewhere could point at); a semantic
// `<ol>` numbers natively, like `steps`. A note with no text is dropped.
function footnoteRowHtml(note: unknown): string {
  if (!isMap(note)) return ''
  const text = str(note.text)
  if (text === '') return ''
  const id = str(note.id)
  const idAttr = id === '' ? '' : ` id="fn-${escapeAttr(id)}"`
  return `<li${idAttr} class="bp-footnote__note">${escapeHtml(text)}</li>`
}

const footnote: Emit = (b) => {
  const rows = asList(b.notes).map(footnoteRowHtml).join('')
  return rows === '' ? '' : `<ol class="bp-footnote">${rows}</ol>`
}

// scaffy:add-block-type Steps MARK:js-emitter-steps
// Mirrors compose_block(steps): starter emit — `text` escaped into
// the bp-steps wrapper, byte-identical to the Elixir _raw clause.
// Mirrors compose_block(steps): a numbered procedure — `steps` is a list of
// {title, blocks}, each recursed through the shared `renderBlocks` dispatcher
// (the columns/terminal precedent). A semantic `<ol>` carries the numbering
// natively; a step with neither a title nor any blocks contributes nothing.
function stepRowHtml(step: unknown): string {
  if (!isMap(step)) return ''
  const title = str(step.title)
  const blocks = asList(step.blocks ?? step.children)
  if (title === '' && blocks.length === 0) return ''

  const body = renderBlocks(blocks)
  const titleHtml = title === '' ? '' : `<div class="bp-steps__title">${escapeHtml(title)}</div>`
  return `<li class="bp-steps__step">${titleHtml}<div class="bp-steps__body">${body}</div></li>`
}

const steps: Emit = (b) => {
  const rows = asList(b.steps).map(stepRowHtml).join('')
  return rows === '' ? '' : `<ol class="bp-steps">${rows}</ol>`
}

// scaffy:add-block-type Toc MARK:js-emitter-toc
// Mirrors compose_block(toc): a static, author-supplied outline — `items` is a
// flat list of {text, level, anchor}, never derived by walking sibling blocks
// (this emitter, like compose_block/2, only ever sees ONE block). `depth` caps
// how many RELATIVE levels show, counted from the shallowest level present
// (default 2); `numbered` prefixes each item with a hierarchical counter
// (1, 1.1, 1.2, 2, …); `sticky` adds the View-only CSS affordance class.
interface TocItem {
  text: string
  level: number
  anchor: string
}

function tocItems(raw: unknown): TocItem[] {
  const out: TocItem[] = []
  for (const it of asList(raw)) {
    if (!isMap(it)) continue
    const text = str(it.text)
    if (text === '') continue
    const n = num(it.level)
    const level = n != null && n > 0 ? n : 1
    out.push({ text, level, anchor: str(it.anchor) })
  }
  return out
}

const toc: Emit = (b) => {
  const items = tocItems(b.items)
  if (items.length === 0) return ''

  const depthNum = num(b.depth)
  const depth = depthNum != null && depthNum > 0 ? depthNum : 2
  const numbered = b.numbered === true
  const minLevel = Math.min(...items.map((i) => i.level))
  const counters = new Array(depth + 1).fill(0)

  const rows: string[] = []
  for (const item of items) {
    const rel = item.level - minLevel + 1
    if (rel > depth) continue
    counters[rel] += 1
    for (let lvl = rel + 1; lvl <= depth; lvl++) counters[lvl] = 0

    let label = escapeHtml(item.text)
    if (numbered) {
      const numStr = counters.slice(1, rel + 1).join('.')
      label = `${numStr}. ${label}`
    }
    const inner =
      item.anchor !== '' ? `<a href="#${escapeAttr(item.anchor)}">${label}</a>` : label
    rows.push(`<li class="bp-toc__item" data-level="${rel}">${inner}</li>`)
  }

  const sticky = b.sticky === true
  const navClass = sticky ? 'bp-toc bp-toc--sticky' : 'bp-toc'
  return `<nav class="${navClass}"><ol class="bp-toc__list">${rows.join('')}</ol></nav>`
}

// scaffy:add-block-type Blockquote MARK:js-emitter-blockquote
// Mirrors compose_block(blockquote) + walk.ex blockquote/3 (:article): a
// semantic `<blockquote class="bp-blockquote">` wrapping a `<p>` body, with an
// optional `<cite>` attribution. Body reads a `content` inline array (else a
// bare `text`) exactly like pullquote/paragraph, so the inner is shape-equal to
// the Elixir article golden the parity harness compares against.
const blockquote: Emit = (b) => {
  const inner = renderInlines(paragraphInline(b))
  const rawCite = str(b.cite) || str(b.attribution)
  const cite = rawCite ? `<cite class="bp-blockquote__cite">${escapeHtml(rawCite)}</cite>` : ''
  return `<blockquote class="bp-blockquote"><p>${inner}</p>${cite}</blockquote>`
}

/* ── code-story blocks: diff + filetree (components.ex, W7 D75–D78) ────────── */
//
// The verbatim-text front-end over the SHARED chat diff-row back-end (D76):
// rows render through chat.ts diffRowsHtml/rowStyle/rowPrefix and fold at the
// same CHAT_DIFF_BUDGET. Byte-identical to Components.diff_html/1 +
// filetree_html/1.

// Order matters: '+++ '/'--- ' match before the bare '+'/'-' ops (D77: git file
// headers never count as +/- rows; each '+++' transition becomes a bold path
// sub-header; '@@' hunk headers stay verbatim dim context rows).
function diffLineRow(line: string): DiffLine[] {
  if (line.startsWith('+++ ')) {
    const path = line.slice(4)
    return [{ op: 'file', text: path.startsWith('b/') ? path.slice(2) : path }]
  }
  if (line.startsWith('--- ')) return []
  if (line.startsWith('diff --git ')) return []
  if (line.startsWith('index ')) return []
  if (line.startsWith('@@')) return [{ op: '', text: line }]
  if (line.startsWith('+')) return [{ op: '+', text: line.slice(1) }]
  if (line.startsWith('-')) return [{ op: '-', text: line.slice(1) }]
  if (line.startsWith(' ')) return [{ op: '', text: line.slice(1) }]
  return [{ op: '', text: line }]
}

// Shared rows via diffRowsHtml; only the diff-only bold path sub-header is
// emitted here (twin of components.ex diff_section_rows_html/1).
function diffSectionRowsHtml(rows: DiffLine[]): string {
  return rows
    .map((row) =>
      row.op === 'file'
        ? `<div style="font-weight: 600; margin: 4px 0 1px; white-space: pre-wrap; overflow-wrap: anywhere;">${escapeHtml(row.text)}</div>`
        : diffRowsHtml([row]),
    )
    .join('')
}

// scaffy:add-block-type Diff MARK:js-emitter-diff
// Mirrors compose_block(diff) → Components.diff_html/1 (W7 grow): the verbatim
// unified-diff `diff` attr parsed at render time (D75), optional file/lang
// metadata leading the +N −M tally, details-fold past CHAT_DIFF_BUDGET rows.
const diff: Emit = (b) => {
  const rows = splitLines(str(b.diff)).flatMap(diffLineRow)
  const added = rows.filter((r) => r.op === '+').length
  const removed = rows.filter((r) => r.op === '-').length
  const head = rows.slice(0, CHAT_DIFF_BUDGET)
  const rest = rows.slice(CHAT_DIFF_BUDGET)

  const file = str(b.file)
  const lang = str(b.lang)
  const lead = [
    file === '' ? '' : `<span style="font-weight: 600;">${escapeHtml(file)}</span>`,
    lang === '' ? '' : escapeHtml(lang),
  ]
    .filter((p) => p !== '')
    .join(' · ')
  const leadHtml = lead === '' ? '' : `${lead} · `

  const counts =
    `<div class="text-dim" style="font-size: 11px; margin-bottom: 4px;">` +
    leadHtml +
    `<span style="color: var(--ok);">+${added}</span> ` +
    `<span style="color: var(--danger);">−${removed}</span></div>`

  let body: string
  if (rows.length > CHAT_DIFF_BUDGET) {
    const overflow = rows.length - CHAT_DIFF_BUDGET
    body =
      `<details><summary style="cursor: pointer; list-style: none;">` +
      diffSectionRowsHtml(head) +
      `<div class="text-dim" style="font-size: 11px; padding: 1px 0;">… +${overflow} more lines</div>` +
      `</summary>${diffSectionRowsHtml(rest)}</details>`
  } else {
    body = diffSectionRowsHtml(head)
  }

  return (
    `<div class="bp-diff text-xs" style="font-family: var(--font-mono); margin: 4px var(--bp-evidence-pull, 0px); width: var(--bp-evidence-width, 100%); box-sizing: border-box; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;">` +
    counts +
    body +
    `</div>`
  )
}

// The D78 annotation markers with their evergreen token colors (glyph is the
// semantic carrier; the legend row disambiguates locally).
const FILETREE_MARKERS: Array<[string, string]> = [
  [' ● ', 'var(--ok)'],
  [' ○ ', 'var(--fg-dim)'],
  [' ✕ ', 'var(--danger)'],
]

function filetreeRowHtml(line: string): string {
  let hit: { idx: number; glyph: string; color: string } | null = null
  for (const [glyph, color] of FILETREE_MARKERS) {
    const idx = line.indexOf(glyph)
    if (idx !== -1 && (hit === null || idx < hit.idx)) hit = { idx, glyph, color }
  }
  if (hit === null) return `<div style="white-space: pre;">${escapeHtml(line)}</div>`
  const path = line.slice(0, hit.idx)
  const note = hit.glyph + line.slice(hit.idx + hit.glyph.length)
  return (
    `<div style="white-space: pre;">${escapeHtml(path)}` +
    `<span class="bp-filetree-note" style="color: ${hit.color};">${escapeHtml(note)}</span></div>`
  )
}

// scaffy:add-block-type Filetree MARK:js-emitter-filetree
// Mirrors compose_block(filetree) → Components.filetree_html/1 (W7 grow):
// verbatim tree lines (white-space: pre), trailing ` ● `/` ○ `/` ✕ `
// annotation spans, optional dim `legend` row (D78).
const filetree: Emit = (b) => {
  const rows = splitLines(str(b.text)).map(filetreeRowHtml).join('')
  const legend = str(b.legend)
  const legendHtml =
    legend === ''
      ? ''
      : `<div class="bp-filetree-legend text-dim" style="font-size: 11px; margin-top: 4px;">${escapeHtml(legend)}</div>`
  return (
    `<div class="bp-filetree text-xs" style="font-family: var(--font-mono); margin: 4px var(--bp-evidence-pull, 0px); width: var(--bp-evidence-width, 100%); box-sizing: border-box; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;">` +
    rows +
    legendHtml +
    `</div>`
  )
}

const byline: Emit = (b) => {
  const items = b.items
  const text = Array.isArray(items) ? items.map((i) => str(i)).join(' · ') : str(b.text)
  return `<p class="bp-role-byline">${escapeHtml(text)}</p>`
}

const ingress: Emit = (b) => `<p class="bp-role-ingress">${renderInlines(paragraphInline(b))}</p>`

// Reader-Owned Spacing Doctrine (/papers/mechanical-spacing-doctrine, flipped
// 2026-07-31): published readers emit only visible semantic groups — an empty
// paragraph scaffold (Enter, Enter) is editable authoring state, NEVER published
// layout, so it renders NOTHING (no element at all), not an empty `<p>`.
// Suppression is exact and narrow (doctrine invariant 4): only a paragraph whose
// inline run is nothing but whitespace text vanishes — any authored non-text
// inline (link/code/tag/valueref/…) or marked run keeps its `<p>` byte-faithful.
// Cadence between the REMAINING blocks stays reader-owned CSS margins (invariant
// 3 — `renderBlocks` joins emitted strings, never spacing by raw array index).
// The Elixir twin is walk.ex `paragraph/3`; legacy cached `<p></p>` HTML is
// belt-and-braces suppressed by `.bp-paper-surface p:empty` in paper-surface.css.
function isBlankParagraphRun(nodes: unknown): boolean {
  if (typeof nodes === 'string') return nodes.trim() === ''
  if (!Array.isArray(nodes)) return false
  return nodes.every(isBlankParagraphNode)
}

function isBlankParagraphNode(n: unknown): boolean {
  if (typeof n === 'string') return n.trim() === ''
  if (typeof n === 'number') return false // renders its digits
  if (Array.isArray(n)) return isBlankParagraphRun(n) // shallow-flattened shape
  if (!isMap(n)) return true // null/bool — renderInline emits '' for these
  // Only an UNMARKED whitespace text leaf counts as scaffold; every other node
  // type (and any marked run) is authored content and keeps the paragraph.
  // Dual-read value || legacy text (textLeafValue): a legacy-keyed leaf with
  // real prose must NOT count as scaffold, or the whole paragraph vanishes.
  return str(n.type) === 'text' && asList(n.marks).length === 0 && textLeafValue(n).trim() === ''
}

const paragraph: Emit = (b) => {
  const inline = paragraphInline(b)
  if (isBlankParagraphRun(inline)) return ''
  return `<p>${renderInlines(inline)}</p>`
}

// Pullquote is a PdParagraph with _role pullquote + italic:true → the role class
// plus the inline italic author mark (walk.ex paragraph/3).
const pullquote: Emit = (b) =>
  `<p class="bp-role-pullquote" style="font-style:italic">${renderInlines(paragraphInline(b))}</p>`

const list: Emit = (b) => {
  const tag = b.ordered === true ? 'ol' : 'ul'
  const items = asList(b.items)
  const inner = items.map((item) => `<li><span>${renderInlines(itemInlines(item))}</span></li>`).join('')
  return `<${tag}>${inner}</${tag}>`
}

// The inline content of ONE list item, whatever authored shape it took. The RN
// twin is apps/mobile/src/papers/portabledoc/model.ts `itemInlines` (shipped
// af9d64d61) — the reference normalization, ported here rather than re-derived:
//
//   array  → inline nodes verbatim
//   string → JSON-decoded inline array (see normalizeListItem), else plain text
//   map    → its own `content` inline array, else its bare `text` (the D12
//            content||text law the heading emitter already carries)
//
// The MAP arm is the fix: it is the DOMINANT authored shape in the live corpus
// (2,033 of 10,455 published list items scanned 2026-07-25 across 537 papers),
// and `renderInlines` returns '' for a map — so every one of those items shipped
// as an empty `<li><span></span></li>` on web. Same defect class as the
// content[]-shape heading fix (289b46b1a / PR #6009), a different emitter.
function itemInlines(item: unknown): unknown {
  const n = normalizeListItem(item)
  return isMap(n) ? paragraphInline(n as Block) : n
}

// Decode a list item persisted as a JSON-encoded inline array (the drifted
// `bullet_list` authoring shape, aliased onto `list` below) into that array;
// otherwise return it verbatim so plain-text items stay plain text. Mirrors
// compose.ex normalize_list_item/1 + pdrender itemNodes.
function normalizeListItem(item: unknown): unknown {
  if (typeof item !== 'string') return item
  const trimmed = item.trim()
  if (!trimmed.startsWith('[')) return item
  try {
    const parsed: unknown = JSON.parse(trimmed)
    if (Array.isArray(parsed) && parsed.length > 0 && isMap(parsed[0])) return parsed
  } catch {
    // not JSON — keep the plain string
  }
  return item
}

// `numbered_list` authoring-drift alias → an ORDERED list (mirrors compose.ex,
// which maps numbered_list → list with ordered:true).
const numberedList: Emit = (b) => list({ ...b, ordered: true } as Block)

/* callout (walk.ex callout/3, article) */

function calloutToneClass(tone: unknown): string {
  switch (str(tone)) {
    case 'success':
      return 'success'
    case 'warning':
      return 'warning'
    case 'danger':
      return 'danger'
    case 'neutral':
      return 'neutral'
    default:
      return 'info'
  }
}

function toneLabel(tone: unknown): string {
  switch (str(tone)) {
    case 'success':
      return 'Success'
    case 'warning':
      return 'Warning'
    case 'danger':
      return 'Danger'
    case 'neutral':
      return 'Neutral'
    default:
      return 'Info'
  }
}

const callout: Emit = (b) => {
  const toneMod = calloutToneClass(b.tone)
  // The callout body slot flattens to ONE PdText wrapping the composed inline
  // children — walk.ex renders it as a bare `<span>`.
  const body = `<span>${renderInlines(paragraphInline(b))}</span>`

  if (b.collapsible === true) {
    const open = b.collapsed === true ? '' : ' open'
    const title = str(b.title)
    const summary = escapeHtml(title !== '' ? title : toneLabel(b.tone))
    return (
      `<details${open} class="bp-callout bp-callout--${toneMod}">` +
      `<summary class="bp-callout__summary">${summary}</summary>` +
      `<div class="bp-callout__body">${body}</div></details>`
    )
  }

  const title = str(b.title)
  const titleHtml = title !== '' ? `<strong>${escapeHtml(title)}</strong> ` : ''
  return `<div class="bp-callout bp-callout--${toneMod}">${titleHtml}${body}</div>`
}

/* code / divider / image (figures.ex + walk.ex) */

const READING_ACCENT = 'var(--paper-reading-accent, #a23925)'
const MONO = 'ui-monospace,Menlo,monospace'

// Shared with `codeTabs` (byte-identical to Figures.code_block_html/1) so a
// code-tabs panel and a standalone `code` block render the same chrome.
function codeBlockHtml(value: string): string {
  const escaped = escapeHtml(value)
  return (
    `<pre style="background:var(--paper-bg-deep, #eaf1ee);border:0;border-radius:var(--bp-codeblock-radius, 0);border-left:var(--bp-codeblock-accent-w, 3px) solid ${READING_ACCENT};color:var(--paper-ink, #15211d);padding:var(--bp-codeblock-pad, 0.9rem 1.1rem);` +
    `margin:var(--bp-codeblock-margin, 1.2rem 0);font-family:var(--paper-font-mono, ${MONO});font-size:var(--bp-codeblock-size, 0.9rem);line-height:var(--bp-codeblock-lh, 1.5);` +
    `overflow-x:auto;white-space:pre">${escaped}</pre>`
  )
}

const code: Emit = (b) => codeBlockHtml(str(b.value))

// The `bp-section-divider` classes carry no styling (every value is inline, the
// same bytes figures.ex emits) — they are the handle the reader shell needs to
// say something about a divider's POSITION, e.g. that one sitting directly in
// front of a section head draws a boundary the head already draws. Kept here so
// an SDK-rendered document is the same document the reader renders.
const divider: Emit = () =>
  `<div class="bp-section-divider" style="position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid var(--paper-rule, #dde7e2)">` +
  `<span class="bp-section-divider__mark" style="position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;` +
  `background:var(--paper-bg-deep, #eaf1ee);color:var(--paper-ink-soft, #55635e);font-size:1.1rem">§</span></div>`

const image: Emit = (b) => {
  const rawSrc = str(b.src).trim()
  if (rawSrc === '') return '' // asset-less image = editor scaffolding, skip on read
  const w = b.width
  const h = b.height
  let dims = ''
  if (w !== null && w !== undefined) dims += ` width="${escapeAttr(str(w) || String(w))}"`
  if (h !== null && h !== undefined) dims += ` height="${escapeAttr(str(h) || String(h))}"`
  return `<img src="${safeUrl(str(b.src))}" alt="${escapeAttr(str(b.alt))}" style="max-width:100%;height:auto"${dims}>`
}

/* figure / diagram / asciicast (figures.ex) */

// Bold "Figure N." run-in split (Figures.figcaption_inner/1).
function figcaptionInner(caption: string): string {
  if (caption === '') return ''
  const m = /^(Figure\s+\S+?\.)\s*([\s\S]*)$/.exec(caption)
  if (m) {
    const rest = m[2]
    const restHtml = rest === '' ? '' : ' ' + escapeHtml(rest)
    return `<b>${escapeHtml(m[1])}</b>${restHtml}`
  }
  return escapeHtml(caption)
}

function articleFigcaption(caption: string): string {
  if (caption === '') return ''
  return `<figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #55635e);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif;max-width:var(--bp-evidence-caption, 72ch)">${figcaptionInner(caption)}</figcaption>`
}

// asciicast_html/3 (:article) uses a PLAIN `#55635e` figcaption color — NOT the
// `var(--paper-ink-soft, …)` the figure/diagram captions use (figures.ex line 124
// vs 88). Mirror that divergence exactly, or the DOM-shape style attribute diverges.
function asciicastFigcaption(caption: string): string {
  if (caption === '') return ''
  return `<figcaption style="margin-top:0.8rem;color:#55635e;font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif;max-width:var(--bp-evidence-caption, 72ch)">${figcaptionInner(caption)}</figcaption>`
}

// Entity-encode ONLY & < > for the Mermaid source (Figures.encode_mermaid/1).
function encodeMermaid(source: string): string {
  return source.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

const figure: Emit = (b) => {
  const child = b.child
  const caption = str(b.caption)
  const childHtml = isMap(child) ? renderBlock(child as Block) : ''
  return `<figure style="margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto">${childHtml}${articleFigcaption(caption)}</figure>`
}

const diagram: Emit = (b) => {
  const source = str(b.source)
  const caption = str(b.caption)
  return (
    `<figure style="margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;padding:1.2rem;background:var(--paper-bg-deep, #eaf1ee);border:1px solid var(--paper-rule, #dde7e2);border-radius:4px;overflow-x:auto">` +
    `<pre class="mermaid">${encodeMermaid(source)}</pre>` +
    articleFigcaption(caption) +
    `</figure>`
  )
}

// `poster` (optional) is the block's resting frame — the asciinema-player
// `poster` option, an npt timestamp (`"npt:1:23"`) or `"end"`. It rides
// `data-cast-poster` and is emitted ONLY when set, so an unset poster keeps
// the mount byte-identical to Figures.asciicast_html's and leaves the
// `npt:0:1` fallback with the hydrating clients (client.ts / the LiveView
// hook). Attribute-escaped, NOT `safeUrl` — a poster is a timestamp, not a URL.
const asciicast: Emit = (b) => {
  const src = str(b.src)
  const caption = str(b.caption)
  const poster = str(b.poster).trim()
  const posterAttr = poster === '' ? '' : ` data-cast-poster="${escapeAttr(poster)}"`
  return (
    `<figure style="margin:var(--bp-air-asciicast, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto">` +
    `<div class="bp-asciicast" data-cast-src="${safeUrl(src)}"${posterAttr} style="border:1px solid #dde7e2;border-radius:6px;overflow:hidden"></div>` +
    asciicastFigcaption(caption) +
    `</figure>`
  )
}

// scaffy:add-block-type Video MARK:js-emitter-video
// Mirrors compose_block(video) (:article) — the JS twin of Figures.video_html.
// Plain <video> file block (B062): a native <video controls> element, zero
// client JS. An asset-less video (no `src`) renders nothing — the `image`
// precedent (editor scaffolding, skipped). `captions` is filtered to maps.
const video: Emit = (b) => {
  const src = str(b.src).trim()
  if (src === '') return ''

  const poster = str(b.poster).trim()
  const posterAttr = poster === '' ? '' : ` poster="${safeUrl(poster)}"`
  const loopAttr = b.loop === true ? ' loop' : ''

  const tracks = asList(b.captions)
    .filter(isMap)
    .map((c) => {
      const lang = str(c.lang)
      const trackSrc = str(c.src)
      const langAttr = lang === '' ? '' : ` srclang="${escapeAttr(lang)}"`
      return `<track kind="captions"${langAttr} src="${safeUrl(trackSrc)}">`
    })
    .join('')

  return (
    `<figure style="margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto">` +
    `<video controls playsinline style="max-width:100%;border-radius:6px"${posterAttr}${loopAttr} src="${safeUrl(src)}">` +
    tracks +
    `</video></figure>`
  )
}

/* action (walk.ex button/2) */

const action: Emit = (b) => {
  const label = escapeHtml(str(b.label))
  const href = safeUrl(str(b.href))
  const cls = b.priority === 'primary' ? 'bp-button bp-button--primary' : 'bp-button'
  return `<a href="${href}" class="${cls}">${label}</a>`
}

/* paper-links (compose.ex paper_links_html) — authored refs render everywhere;
 * `_paper_links` may carry transient live metadata injected by a reader. */

interface PaperLinkRef {
  slug: string
  title: string
  description: string
  reason: string
  eventType: string
  rev: string
  updatedAt: string
}

function nonblank(v: unknown): string {
  return str(v).trim()
}

function paperLinkRef(
  raw: unknown,
  resolved: Record<string, unknown>,
  reasons: Record<string, unknown>,
): PaperLinkRef | undefined {
  const ref = typeof raw === 'string' ? { slug: raw } : isMap(raw) ? raw : undefined
  if (ref === undefined) return undefined
  const slug = nonblank(ref.slug)
  if (slug === '') return undefined
  const live = isMap(resolved[slug]) ? resolved[slug] : {}

  return {
    slug,
    title: nonblank(live.title) || nonblank(ref.title) || slug,
    description: nonblank(live.description) || nonblank(ref.description),
    reason: nonblank(ref.reason) || nonblank(reasons[slug]),
    eventType: nonblank(live.event_type),
    rev: nonblank(live.rev),
    updatedAt: nonblank(live.updated_at),
  }
}

function normalizedCopy(copy: string): string {
  return copy.trim().replace(/\.+$/, '').toLowerCase()
}

function paperLinkCard(ref: PaperLinkRef): string {
  const description =
    ref.description === ''
      ? ''
      : `<span style="display:block;margin-top:0.42rem;color:var(--paper-ink-soft, #55635e);line-height:1.55">${escapeHtml(ref.description)}</span>`
  const reason =
    ref.reason !== '' && normalizedCopy(ref.reason) !== normalizedCopy(ref.description)
      ? `<span style="display:block;margin-top:0.65rem;color:var(--paper-ink, #17332d);font-size:0.88rem;line-height:1.45"><strong>Why it matters:</strong> ${escapeHtml(ref.reason)}</span>`
      : ''
  const metadataParts = [ref.eventType, ref.rev === '' ? '' : `rev ${ref.rev}`, ref.updatedAt].filter(Boolean)
  const metadata =
    metadataParts.length === 0
      ? ''
      : `<span style="display:block;margin-top:0.7rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.72rem;letter-spacing:0.025em;color:var(--paper-ink-soft, #55635e)">${escapeHtml(metadataParts.join(' · '))}</span>`

  return (
    `<a data-paper-link-card href="${safeUrl(`/papers/${ref.slug}`)}" style="display:block;padding:1.15rem 1.2rem;border:1px solid var(--paper-rule, #dde7e2);border-left:3px solid var(--paper-accent, #1e5347);border-radius:0.65rem;background:var(--paper-accent-soft, rgba(30,83,71,0.10));color:inherit;text-decoration:none">` +
    `<strong style="display:block;font-size:1.02rem;line-height:1.35;color:var(--paper-accent, #1e5347)">${escapeHtml(ref.title)}</strong>` +
    description +
    reason +
    metadata +
    `</a>`
  )
}

const paperLinks: Emit = (b) => {
  const resolved = isMap(b._paper_links) ? b._paper_links : {}
  const reasons = isMap(b.reasons) ? b.reasons : {}
  const cards = asList(b.refs)
    .map((ref) => paperLinkRef(ref, resolved, reasons))
    .filter((ref): ref is PaperLinkRef => ref !== undefined)
    .map(paperLinkCard)
    .join('')
  if (cards === '') return ''

  const title = nonblank(b.title) || 'Explore the work'
  const description = nonblank(b.description)
  const intro =
    description === ''
      ? ''
      : `<p style="margin:0.45rem 0 0;color:var(--paper-ink-soft, #55635e);line-height:1.6">${escapeHtml(description)}</p>`

  return (
    `<section data-paper-links aria-label="${escapeAttr(title)}" style="margin:2.8rem 0 0;padding-top:1.35rem;border-top:1px solid var(--paper-rule, #dde7e2)">` +
    `<header style="margin:0 0 1.15rem"><h2 style="margin:0;font-size:1.15rem;line-height:1.25;color:var(--paper-ink, #17332d)">${escapeHtml(title)}</h2>${intro}</header>` +
    `<div style="display:grid;gap:0.85rem">${cards}</div></section>`
  )
}

/* section (compose.ex section_grid_html / compose_section_stack) */

function gridTracks(n: unknown): number {
  if (typeof n === 'number' && Number.isInteger(n) && n > 0) return n
  if (typeof n === 'string' && /^\d+$/.test(n)) {
    const i = Number.parseInt(n, 10)
    if (i > 0) return i
  }
  return 2
}

function gapTokenVar(gap: unknown): string {
  switch (gap) {
    case 'none':
      return 'var(--bp-space-none,0)'
    case 'sm':
      return 'var(--bp-space-sm,0.8rem)'
    case 'lg':
      return 'var(--bp-space-lg,2.4rem)'
    default:
      return 'var(--bp-space-md,1.6rem)'
  }
}

function spanInt(v: unknown): number | null {
  if (typeof v === 'number' && Number.isInteger(v) && v > 0) return v
  if (typeof v === 'string' && /^\d+$/.test(v)) {
    const i = Number.parseInt(v, 10)
    if (i > 0) return i
  }
  return null
}

function orderInt(v: unknown): number | null {
  if (typeof v === 'number' && Number.isInteger(v)) return v
  if (typeof v === 'string' && /^-?\d+$/.test(v)) return Number.parseInt(v, 10)
  return null
}

// Present-only `order:K;grid-column:span N` (order-then-span join, matching
// cell_layout_attr/1).
function cellLayoutAttr(child: unknown): string {
  if (!isMap(child)) return ''
  const parts: string[] = []
  const order = orderInt(child.order)
  if (order !== null) parts.push(`order:${order}`)
  const span = spanInt(child.span)
  if (span !== null) parts.unshift(`grid-column:span ${span}`)
  return parts.length ? ` style="${parts.join(';')}"` : ''
}

const HR = '<hr class="bp-hr">'
const HR_STACK = '<hr class="bp-hr" style="border-top-width:1px">'

const section: Emit = (b) => {
  const layout = b.layout
  const isGrid = isMap(layout) && layout.mode === 'grid'
  const blocks = asList<Block>(b.blocks)

  if (isGrid) {
    const tracks = gridTracks(layout.tracks)
    const gap = gapTokenVar(layout.gap)
    const titleHtml =
      b.title != null
        ? `<div class="bp-section__title" style="font-weight:bold">${escapeHtml(str(b.title))}</div>`
        : ''
    const cells = blocks
      .map(
        (child) =>
          `<div class="bp-section__cell"${cellLayoutAttr(child)}>${renderBlocks([child])}</div>`,
      )
      .join('')
    return (
      `<div style="display:flex;flex-direction:column">` +
      HR +
      titleHtml +
      `<div class="bp-section__grid" style="--bp-tracks:${tracks};--bp-grid-gap:${gap}">` +
      cells +
      `</div>` +
      HR +
      `</div>`
    )
  }

  // Stack section: PdHr, [bold title span], inner blocks, PdHr.
  const titleSpan =
    b.title != null ? `<span style="font-weight:bold">${escapeHtml(str(b.title))}</span>` : ''
  const inner = blocks.map((child) => renderBlock(child)).join('')
  return (
    `<div style="display:flex;flex-direction:column">` +
    HR_STACK +
    titleSpan +
    inner +
    HR_STACK +
    `</div>`
  )
}

/* columns (compose.ex :article) */

const columns: Emit = (b) => {
  const cols = asList(b.columns)
  const n = Math.max(cols.length, 1)
  const inner = cols
    .map((col) => `<div class="bp-cols__c">${renderBlocks(asList<Block>(col))}</div>`)
    .join('')
  return `<div class="bp-cols" style="--bp-cols:${n}">${inner}</div>`
}

/* terminal (compose.ex :article) */

const terminal: Emit = (b) => {
  const title = escapeHtml(str(b.title))
  const footer = str(b.footer)
  const kids = asList<Block>(b.children ?? b.blocks)
  const body = renderBlocks(kids)
  const live =
    b.live === true || b.live === 'true' || b.live === 'live'
      ? `<span class="bp-term__live">live</span>`
      : ''
  const foot = footer === '' ? '' : `<div class="bp-term__foot">${escapeHtml(footer)}</div>`
  return (
    `<div class="bp-term"><div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span>` +
    `<span class="bp-term__title">${title}</span>${live}</div>` +
    `<div class="bp-term__body">${body}</div>${foot}</div>`
  )
}

/* ── task-tracking / composition family (components.ex) ────────────────────── */

function priorityHtml(p: unknown): string {
  const s = str(p).trim()
  if (s === '') return ''
  const digits = s.replace(/[^0-9]/g, '')
  const label = digits === '' ? 'P?' : 'P' + digits
  return `<span class="bp-trow__p" data-p="${digits}">${label}</span>`
}

function criteriaHtml(c: unknown): string {
  if (!isMap(c)) return ''
  const m = c.met
  const t = c.total
  if (typeof m === 'number' && typeof t === 'number' && t > 0) {
    return `<span class="bp-trow__cn">${m}/${t}</span>`
  }
  return ''
}

function workerHtml(w: unknown): string {
  const s = str(w).trim()
  return s === '' ? '' : `<span class="bp-trow__w">${escapeHtml(s)}</span>`
}

function blockedHtml(b: unknown): string {
  const s = str(b).trim()
  return s === '' ? '' : `<span class="bp-trow__blk">! ${escapeHtml(s)}</span>`
}

function truthy(v: unknown): boolean {
  return v === true || v === 'true' || v === 1
}

function countRole(rows: Block[], r: string): number {
  return rows.filter((row) => roleOf(row.status) === r).length
}

const statusLegend: Emit = () => {
  // LEGEND_ROLES (not STATUS_ROLES) — the manifest-scoped vocabulary key, frozen
  // to the Elixir golden. The fail-open `unknown` sentinel and the not-yet-in-
  // manifest thought states are excluded (see inline.tsx LEGEND_ROLES).
  const rows = LEGEND_ROLES.map((r) => {
    const name = escapeHtml(labelForRole(r.role))
    const meaning = meaningForRole(r.role)
    return `<div class="bp-legend__r">${glyphHtml(r.role)}<span class="bp-legend__n">${name}</span><span class="bp-legend__d">${meaning}</span></div>`
  }).join('')
  return `<div class="bp-legend">${rows}</div>`
}

function noteItemHtml(item: unknown): string {
  const m = isMap(item) ? item : {}
  const label = escapeHtml(str(m.label))
  // Swept sibling of the heading/list content[] defect: the note body read
  // `text` alone, blanking the live note persisted as `{content:[…]}`. The
  // `text` path is byte-identical, so notes.golden.json is untouched.
  const text = renderInlines(paragraphInline(m as Block))
  const lead = str(m.lead).trim()
  const leadHtml = lead === '' ? '' : `<b>${escapeHtml(lead)}</b> `
  return `<div class="bp-note"><span class="bp-note__k">${label}</span><div class="bp-note__d">${leadHtml}${text}</div></div>`
}

const notes: Emit = (b) => {
  const items = asList(b.items)
  if (items.length === 0) return ''
  return `<div class="bp-notes">${items.map(noteItemHtml).join('')}</div>`
}

const note: Emit = (b) => noteItemHtml(b)

const cards: Emit = (b) => {
  const items = asList(b.items)
  if (items.length === 0) return ''
  const inner = items
    .map((it) => {
      const m = isMap(it) ? it : {}
      const title = escapeHtml(str(m.title))
      const text = escapeHtml(str(m.text))
      const tone = str(m.tone)
      const toneCls = ['info', 'ok', 'warn', 'danger'].includes(tone) ? ` bp-card--${tone}` : ''
      const titleHtml = title === '' ? '' : `<div class="bp-card__t">${title}</div>`
      const textHtml = text === '' ? '' : `<div class="bp-card__d">${text}</div>`
      return `<div class="bp-card${toneCls}">${titleHtml}${textHtml}</div>`
    })
    .join('')
  return `<div class="bp-cards">${inner}</div>`
}

// card (MODEL B) — slot children recursed in order media/title/body/action.
function slotElements(block: Block, name: string): Block[] {
  if (!isMap(block.slots)) return []
  return asList<Block>(block.slots[name])
}

function normalizeMedia(el: unknown): Block {
  if (isMap(el) && 'type' in el) return el as Block
  if (isMap(el)) return { ...(el as Record<string, unknown>), type: 'image' } as Block
  return el as Block
}

const card: Emit = (b) => {
  const tone = str(b.tone)
  const toneCls = ['info', 'ok', 'warn', 'danger'].includes(tone) ? ` bp-card--${tone}` : ''
  const media = renderBlocks(slotElements(b, 'media').map(normalizeMedia))
  const inner =
    media +
    renderBlocks(slotElements(b, 'title')) +
    renderBlocks(slotElements(b, 'body')) +
    renderBlocks(slotElements(b, 'action'))
  return `<div class="bp-card${toneCls}">${inner}</div>`
}

// pnode source coercion (Components.pnode_source/1).
function pnodeSource(node: Record<string, unknown>): [string, string] {
  const s = node.source
  if (s === true) return [' bp-pnode--src', '']
  if (typeof s === 'string' && s !== '')
    return ['', `<div class="bp-pnode__src">${escapeHtml(s)}</div>`]
  return ['', '']
}

function pnodeCell(n: Record<string, unknown>): string {
  const k = escapeHtml(str(n.kind))
  const t = escapeHtml(str(n.title))
  const d = escapeHtml(str(n.detail))
  const f = escapeHtml(str(n.files))
  const [srcClass, srcHtml] = pnodeSource(n)
  const kh = k === '' ? '' : `<div class="bp-pnode__k">${k}</div>`
  const th = t === '' ? '' : `<div class="bp-pnode__t">${t}</div>`
  const dh = d === '' ? '' : `<div class="bp-pnode__d">${d}</div>`
  const fh = f === '' ? '' : `<div class="bp-pnode__f">${f}</div>`
  return `<div class="bp-pnode${srcClass}">${kh}${th}${dh}${fh}${srcHtml}</div>`
}

const pipeline: Emit = (b) => {
  const nodes = asList(b.nodes)
  if (nodes.length === 0) return ''
  const cells = nodes
    .map((n) => pnodeCell(isMap(n) ? n : {}))
    .join(`<span class="bp-pipe__arr">→</span>`)
  return `<div class="bp-pipe-scroll"><div class="bp-pipe">${cells}</div></div>`
}

// stage — the editable per-node twin of ONE pipeline node (slots OR scalars).
const stage: Emit = (b) => {
  const stageField = (name: string): unknown => {
    if (isMap(b.slots)) {
      const els = asList(b.slots[name])
      if (els.length) {
        // slot-materialized: join the text of its element children
        return els.map((e) => (isMap(e) ? str(e.text) : str(e))).join('')
      }
    }
    return b[name]
  }
  return pnodeCell({
    kind: stageField('kind'),
    title: stageField('title'),
    detail: stageField('detail'),
    files: b.files,
    source: b.source,
  })
}

/* task-detail (components.ex task_detail_html) */

function priorityLabel(p: unknown): string | null {
  const digits = str(p)
    .trim()
    .replace(/[^0-9]/g, '')
  return digits === '' ? null : 'P' + digits
}

function taskDetail(b: Block): string {
  const t = isMap(b.task) ? b.task : b
  const title = str(t.title).trim()
  if (title === '') return ''
  const role = roleOf(t.status)

  const sections: string[] = []

  // meta
  {
    const parts = [
      str(t.status) || null,
      priorityLabel(t.priority),
      str(t.kind) || null,
      str(t.worker) || null,
    ]
      .filter((x): x is string => x != null && x !== '')
      .map(escapeHtml)
      .join(' · ')
    sections.push(`<div class="bp-tdetail__meta">${glyphHtml(role)}<span>${parts}</span></div>`)
  }
  // stamp
  {
    const c = str(t.created).trim()
    const u = str(t.updated).trim()
    const line = [
      c !== '' ? `created ${escapeHtml(c)}` : '',
      u !== '' ? `updated ${escapeHtml(u)}` : '',
    ]
      .filter(Boolean)
      .join(' · ')
    if (line !== '') sections.push(`<div class="bp-tdetail__stamp">${line}</div>`)
  }
  // timeline
  {
    const segs = asList(t.timeline)
    if (segs.length) {
      const cells = segs
        .map((s) => {
          const m = isMap(s) ? s : {}
          const r = roleOf(m.status)
          const lbl = escapeHtml(str(m.label))
          return `<span class="bp-tl__seg">${glyphHtml(r)}<span>${lbl}</span></span>`
        })
        .join(`<span class="bp-tl__arr">→</span>`)
      sections.push(`<div class="bp-tdetail__timeline">${cells}</div>`)
    }
  }
  // description
  {
    const d = str(t.description).trim()
    if (d !== '') sections.push(`<div class="bp-tdetail__desc">${escapeHtml(d)}</div>`)
  }
  // criteria
  {
    const items = asList(t.criteria)
    if (items.length) {
      const met = items.filter((c) => truthy(isMap(c) ? c.met : false)).length
      const total = items.length
      const rows = items
        .map((c) => {
          const m = isMap(c) ? c : {}
          const done = truthy(m.met)
          const g = done ? glyphHtml('done') : glyphHtml('ready')
          const txtRaw = str(m.text) !== '' ? str(m.text) : str(m.criterion)
          const txt = escapeHtml(txtRaw)
          const ev = str(m.evidence).trim()
          const evHtml = ev === '' ? '' : `<div class="bp-crit__ev">↳ ${escapeHtml(ev)}</div>`
          const cls = done ? ' bp-crit--met' : ''
          return `<div class="bp-crit${cls}">${g}<span class="bp-crit__t">${txt}</span></div>${evHtml}`
        })
        .join('')
      sections.push(
        `<div class="bp-tdetail__lbl">Criteria · ${met}/${total}</div><div class="bp-tdetail__crit">${rows}</div>`,
      )
    }
  }
  // deps
  {
    const blocks = typeof t.blocks === 'number' ? t.blocks : 0
    const blocked = typeof t.blocked_by === 'number' ? t.blocked_by : 0
    const words = [
      blocks > 0 ? `blocks ${blocks} ${blocks === 1 ? 'task' : 'tasks'}` : '',
      blocked > 0 ? `blocked by ${blocked}` : '',
    ]
      .filter(Boolean)
      .join(' · ')
    if (words !== '')
      sections.push(
        `<div class="bp-tdetail__lbl">Dependencies</div><div class="bp-tdetail__deps">${words}</div>`,
      )
  }
  // children rail
  sections.push(detailRail(t, 'children', 'Children'))
  // papers rail
  {
    const rows = asList(t.papers)
    if (rows.length) {
      const shown = rows.slice(0, 10)
      const extra = rows.length - shown.length
      const body = shown
        .map((p) => `<div class="bp-rail__r bp-rail__paper">▸ ${escapeHtml(str(p))}</div>`)
        .join('')
      const more = extra <= 0 ? '' : `<div class="bp-rail__more">… and ${extra} more</div>`
      sections.push(
        `<div class="bp-tdetail__lbl">Papers</div><div class="bp-tdetail__rail">${body}${more}</div>`,
      )
    }
  }
  // labels
  {
    const labels = asList(t.labels)
      .map((l) => str(l))
      .filter((l) => l !== '')
    if (labels.length)
      sections.push(`<div class="bp-tdetail__labels">${labels.map(escapeHtml).join(' · ')}</div>`)
  }

  const joined = sections.filter((s) => s !== '').join('')
  return `<div class="bp-tdetail"><div class="bp-tdetail__title">${escapeHtml(title)}</div>${joined}</div>`
}

function detailRail(t: Record<string, unknown>, key: string, label: string): string {
  const rows = asList(t[key])
  if (rows.length === 0) return ''
  const shown = rows.slice(0, 20)
  const extra = rows.length - shown.length
  const done = rows.filter((r) => roleOf(isMap(r) ? r.status : undefined) === 'done').length
  const body = shown
    .map((r) => {
      const m = isMap(r) ? r : {}
      const role = roleOf(m.status)
      const title = escapeHtml(str(m.title))
      return `<div class="bp-rail__r">${glyphHtml(role)}<span>${title}</span></div>`
    })
    .join('')
  const more = extra <= 0 ? '' : `<div class="bp-rail__more">… and ${extra} more</div>`
  return `<div class="bp-tdetail__lbl">${label} · ${done}/${rows.length} done</div><div class="bp-tdetail__rail">${body}${more}</div>`
}

const taskDetailEmit: Emit = (b) => taskDetail(b)

/* roadmap (components.ex roadmap_html) */

function clampf(n: unknown): number {
  return typeof n === 'number' ? Math.min(Math.max(n, 0), 100) : 0
}
function clampfWidth(n: unknown, left: number): number {
  return typeof n === 'number' ? Math.min(Math.max(n, 1), 100 - left) : Math.max(1, 100 - left)
}

const roadmap: Emit = (b) => {
  const rows = asList(b.snapshot)
  if (rows.length === 0) return `<div class="bp-tasks bp-tasks--empty">No roadmap items.</div>`
  const todayVal = b.today
  const today =
    typeof todayVal === 'number'
      ? `<span class="bp-rm__today" style="left:${clampf(todayVal)}%"></span>`
      : ''
  const scaleCells = asList(b.scale)
  const scale =
    scaleCells.length === 0
      ? ''
      : `<div class="bp-rm__scale">${scaleCells.map((c) => `<span>${escapeHtml(str(c))}</span>`).join('')}</div>`
  const lanes = rows
    .map((r) => {
      const m = isMap(r) ? r : {}
      const role = roleOf(m.status)
      const title = escapeHtml(str(m.title))
      const phase = truthy(m.phase_row)
      const left = clampf(m.left)
      const width = clampfWidth(m.width, left)
      const cls = phase ? 'bp-rm__lane bp-rm__lane--phase' : 'bp-rm__lane'
      return `<div class="${cls}"><span class="bp-rm__lbl">${title}</span><div class="bp-rm__track"><span class="bp-rm__bar bp-rm__bar--${role}" style="left:${left}%;width:${width}%"></span>${today}</div></div>`
    })
    .join('')
  return `<div class="bp-roadmap">${scale}<div class="bp-rm__lanes">${lanes}</div></div>`
}

/* ── exported emitter map ──────────────────────────────────────────────────── */

export const coreEmitters: Record<string, Emit> = {
  heading,
  // h-tag spellings → heading at the level the TYPE names (charter D57): 18 live
  // blocks emitted `bp-unknown-block` on every surface until this landed.
  h1: headingAtLevel(1),
  h2: headingAtLevel(2),
  h3: headingAtLevel(3),
  eyebrow,
  byline,
  ingress,
  paragraph,
  pullquote,
  list,
  // authoring-drift aliases → list / blockquote (the JS twins of compose.ex's
  // alias choke point; agents hand-typed these TipTap/snake/kebab spellings via
  // raw mutate, leaving 77 live prod blocks unrenderable). No data migration.
  bulletList: list,
  bullet_list: list,
  'bulleted-list': list,
  bulleted_list: list,
  numbered_list: numberedList,
  // `ordered-list` is the same emitter under a second spelling (charter D57) — 2
  // live blocks, both with map-shaped items the list emitter already normalizes.
  'ordered-list': numberedList,
  quote: blockquote,
  callout,
  code,
  divider,
  image,
  figure,
  diagram,
  asciicast,
  action,
  'paper-links': paperLinks,
  section,
  columns,
  terminal,
  'status-legend': statusLegend,
  notes,
  note,
  cards,
  card,
  pipeline,
  stage,
  'task-detail': taskDetailEmit,
  roadmap,
  // scaffy:add-block-type Tabs MARK:js-map-tabs
  'tabs': tabs,
  // scaffy:add-block-type CodeTabs MARK:js-map-code-tabs
  'code-tabs': codeTabs,
  // scaffy:add-block-type ApiEndpoint MARK:js-map-api-endpoint
  'api-endpoint': apiEndpoint,
  // scaffy:add-block-type Video MARK:js-map-video
  'video': video,
  // scaffy:add-block-type Expandable MARK:js-map-expandable
  'expandable': expandable,
  // scaffy:add-block-type Footnote MARK:js-map-footnote
  'footnote': footnote,
  // scaffy:add-block-type Steps MARK:js-map-steps
  'steps': steps,
  // scaffy:add-block-type Toc MARK:js-map-toc
  'toc': toc,
  // scaffy:add-block-type Blockquote MARK:js-map-blockquote
  'blockquote': blockquote,
  // scaffy:add-block-type Filetree MARK:js-map-filetree
  'filetree': filetree,
  // scaffy:add-block-type Diff MARK:js-map-diff
  'diff': diff,
}

// shared task-row meta helpers (reused by taskboard.ts)
export { priorityHtml, criteriaHtml, workerHtml, blockedHtml, truthy, countRole }

// re-export so PortableDoc's own empty-state check can share the utils
export { escapeHtml, str, asList, num, isMap }
