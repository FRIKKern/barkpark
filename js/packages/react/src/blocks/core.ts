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
  glyphChar,
  STATUS_ROLES,
} from '../inline'
import { renderBlock, renderBlocks } from './registry'

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
  const level = raw === 1 || raw === 2 || raw === 3 || raw === '1' || raw === '2' || raw === '3' ? Number(raw) : 2
  return `<h${level}>${escapeHtml(str(b.text))}</h${level}>`
}

const eyebrow: Emit = (b) =>
  `<p class="bp-role-eyebrow">${escapeHtml(str(b.text))}</p>`

const byline: Emit = (b) => {
  const items = b.items
  const text = Array.isArray(items)
    ? items.map((i) => str(i)).join(' · ')
    : str(b.text)
  return `<p class="bp-role-byline">${escapeHtml(text)}</p>`
}

const ingress: Emit = (b) =>
  `<p class="bp-role-ingress">${renderInlines(paragraphInline(b))}</p>`

const paragraph: Emit = (b) =>
  `<p>${renderInlines(paragraphInline(b))}</p>`

// Pullquote is a PdParagraph with _role pullquote + italic:true → the role class
// plus the inline italic author mark (walk.ex paragraph/3).
const pullquote: Emit = (b) =>
  `<p class="bp-role-pullquote" style="font-style:italic">${renderInlines(paragraphInline(b))}</p>`

const list: Emit = (b) => {
  const tag = b.ordered === true ? 'ol' : 'ul'
  const items = asList(b.items)
  const inner = items
    .map((item) => `<li><span>${renderInlines(item)}</span></li>`)
    .join('')
  return `<${tag}>${inner}</${tag}>`
}

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

const code: Emit = (b) => {
  const value = escapeHtml(str(b.value))
  return (
    `<pre style="background:var(--paper-bg-deep, #eaf1ee);border:0;border-radius:var(--bp-codeblock-radius, 0);border-left:var(--bp-codeblock-accent-w, 3px) solid ${READING_ACCENT};color:var(--paper-ink, #15211d);padding:var(--bp-codeblock-pad, 0.9rem 1.1rem);` +
    `margin:var(--bp-codeblock-margin, 1.2rem 0);font-family:var(--paper-font-mono, ${MONO});font-size:var(--bp-codeblock-size, 0.9rem);line-height:var(--bp-codeblock-lh, 1.5);` +
    `overflow-x:auto;white-space:pre">${value}</pre>`
  )
}

const divider: Emit = () =>
  `<div style="position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid var(--paper-rule, #dde7e2)">` +
  `<span style="position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;` +
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
  return `<figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #55635e);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif">${figcaptionInner(caption)}</figcaption>`
}

// Entity-encode ONLY & < > for the Mermaid source (Figures.encode_mermaid/1).
function encodeMermaid(source: string): string {
  return source.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

const figure: Emit = (b) => {
  const child = b.child
  const caption = str(b.caption)
  const childHtml = isMap(child) ? renderBlock(child as Block) : ''
  return `<figure style="margin:1.6rem 0">${childHtml}${articleFigcaption(caption)}</figure>`
}

const diagram: Emit = (b) => {
  const source = str(b.source)
  const caption = str(b.caption)
  return (
    `<figure style="margin:1.6rem 0;padding:1.2rem;background:var(--paper-bg-deep, #eaf1ee);border:1px solid var(--paper-rule, #dde7e2);border-radius:4px">` +
    `<pre class="mermaid">${encodeMermaid(source)}</pre>` +
    articleFigcaption(caption) +
    `</figure>`
  )
}

const asciicast: Emit = (b) => {
  const src = str(b.src)
  const caption = str(b.caption)
  return (
    `<figure style="margin:1.6rem 0">` +
    `<div class="bp-asciicast" data-cast-src="${safeUrl(src)}" style="border:1px solid #dde7e2;border-radius:6px;overflow:hidden"></div>` +
    articleFigcaption(caption) +
    `</figure>`
  )
}

/* action (walk.ex button/2) */

const action: Emit = (b) => {
  const label = escapeHtml(str(b.label))
  const href = safeUrl(str(b.href))
  const cls = b.priority === 'primary' ? 'bp-button bp-button--primary' : 'bp-button'
  return `<a href="${href}" class="${cls}">${label}</a>`
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
  const rows = STATUS_ROLES.map((r) => {
    const name = escapeHtml(labelForRole(r.role))
    const meaning = meaningForRole(r.role)
    return `<div class="bp-legend__r">${glyphHtml(r.role)}<span class="bp-legend__n">${name}</span><span class="bp-legend__d">${meaning}</span></div>`
  }).join('')
  return `<div class="bp-legend">${rows}</div>`
}

function noteItemHtml(item: unknown): string {
  const m = isMap(item) ? item : {}
  const label = escapeHtml(str(m.label))
  const text = escapeHtml(str(m.text))
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
  if (typeof s === 'string' && s !== '') return ['', `<div class="bp-pnode__src">${escapeHtml(s)}</div>`]
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
  const digits = str(p).trim().replace(/[^0-9]/g, '')
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
    const line = [c !== '' ? `created ${escapeHtml(c)}` : '', u !== '' ? `updated ${escapeHtml(u)}` : '']
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
      sections.push(`<div class="bp-tdetail__lbl">Criteria · ${met}/${total}</div><div class="bp-tdetail__crit">${rows}</div>`)
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
      sections.push(`<div class="bp-tdetail__lbl">Dependencies</div><div class="bp-tdetail__deps">${words}</div>`)
  }
  // children rail
  sections.push(detailRail(t, 'children', 'Children'))
  // papers rail
  {
    const rows = asList(t.papers)
    if (rows.length) {
      const shown = rows.slice(0, 10)
      const extra = rows.length - shown.length
      const body = shown.map((p) => `<div class="bp-rail__r bp-rail__paper">▸ ${escapeHtml(str(p))}</div>`).join('')
      const more = extra <= 0 ? '' : `<div class="bp-rail__more">… and ${extra} more</div>`
      sections.push(`<div class="bp-tdetail__lbl">Papers</div><div class="bp-tdetail__rail">${body}${more}</div>`)
    }
  }
  // labels
  {
    const labels = asList(t.labels).map((l) => str(l)).filter((l) => l !== '')
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
    typeof todayVal === 'number' ? `<span class="bp-rm__today" style="left:${clampf(todayVal)}%"></span>` : ''
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
  eyebrow,
  byline,
  ingress,
  paragraph,
  pullquote,
  list,
  callout,
  code,
  divider,
  image,
  figure,
  diagram,
  asciicast,
  action,
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
}

// shared task-row meta helpers (reused by taskboard.ts)
export { priorityHtml, criteriaHtml, workerHtml, blockedHtml, truthy, countRole }

// re-export so PortableDoc's own empty-state check can share the utils
export { escapeHtml, str, asList, num, isMap }
