// Block renderers — the RN sibling of js/packages/react/src/blocks/*.ts
// (the @barkpark/react string emitters), mirroring TRAVERSAL SEMANTICS, not
// DOM output: which fields each type reads, the content||text fallback law
// (D12), list-item normalization, container recursion, and the unknown-block
// degrade. Coverage is corpus-driven — a 100-paper census of live production
// (2026-07-25) puts the types below at >99% of all blocks; everything else
// renders the honest labeled fallback (never a crash, never a silent hole,
// logged once per type).
//
// Every renderer is a PURE function (no hooks) so jest can walk the element
// trees without a native host. The two stateful leaves — MermaidIsland
// (WebView island) and nothing else — are mounted as component elements the
// walker treats as leaves.
import type { ReactNode } from 'react'
import { Text, View, Image, ScrollView } from 'react-native'

import type { Theme } from '../../ui/theme'
import { MermaidIsland } from './MermaidIsland'
import { renderInlineNodes, type InlineCtx } from './inlines'
import {
  asList,
  headingLevel,
  isMap,
  itemInlines,
  num,
  openableUrl,
  paragraphInline,
  str,
  type Block,
} from './model'

export interface BlockCtx extends InlineCtx {
  theme: Theme
}

type Render = (b: Block, ctx: BlockCtx, key: number) => ReactNode

/* ── shared text styles ─────────────────────────────────────────────────────── */

const SERIF = 'serif'
const MONO = 'monospace'
const BODY_SIZE = 16
const BODY_LINE = 26

function bodyText(theme: Theme) {
  return { fontFamily: SERIF, fontSize: BODY_SIZE, lineHeight: BODY_LINE, color: theme.text }
}

/* ── prose core ─────────────────────────────────────────────────────────────── */

const HEADING_STYLE: Record<1 | 2 | 3, { fontSize: number; marginTop: number }> = {
  1: { fontSize: 26, marginTop: 24 },
  2: { fontSize: 22, marginTop: 20 },
  3: { fontSize: 18, marginTop: 16 },
}

const heading: Render = (b, ctx, key) => {
  const level = headingLevel(b)
  const s = HEADING_STYLE[level]
  return (
    <Text
      key={key}
      accessibilityRole="header"
      style={{
        fontWeight: '700',
        fontSize: s.fontSize,
        marginTop: s.marginTop,
        marginBottom: 6,
        lineHeight: s.fontSize * 1.3,
        color: ctx.theme.text,
      }}
    >
      {renderInlineNodes(paragraphInline(b), ctx)}
    </Text>
  )
}

const paragraph: Render = (b, ctx, key) => (
  <Text key={key} style={[bodyText(ctx.theme), { marginVertical: 6 }]}>
    {renderInlineNodes(paragraphInline(b), ctx)}
  </Text>
)

const eyebrow: Render = (b, ctx, key) => (
  <Text
    key={key}
    style={{
      fontSize: 12,
      fontWeight: '700',
      letterSpacing: 1.2,
      textTransform: 'uppercase',
      color: ctx.theme.accent,
      marginTop: 14,
      marginBottom: 2,
    }}
  >
    {str(b.text)}
  </Text>
)

const byline: Render = (b, ctx, key) => {
  const items = b.items
  const text = Array.isArray(items) ? items.map((i) => str(i)).join(' · ') : str(b.text)
  return (
    <Text key={key} style={{ fontSize: 13, color: ctx.theme.textMuted, marginVertical: 4 }}>
      {text}
    </Text>
  )
}

const ingress: Render = (b, ctx, key) => (
  <Text
    key={key}
    style={{
      fontFamily: SERIF,
      fontSize: 19,
      lineHeight: 30,
      color: ctx.theme.text,
      marginVertical: 8,
    }}
  >
    {renderInlineNodes(paragraphInline(b), ctx)}
  </Text>
)

const pullquote: Render = (b, ctx, key) => (
  <Text
    key={key}
    style={{
      fontFamily: SERIF,
      fontStyle: 'italic',
      fontSize: 20,
      lineHeight: 30,
      color: ctx.theme.text,
      marginVertical: 14,
      paddingHorizontal: 12,
      textAlign: 'center',
    }}
  >
    {renderInlineNodes(paragraphInline(b), ctx)}
  </Text>
)

const list: Render = (b, ctx, key) => {
  const ordered = b.ordered === true
  const items = asList(b.items)
  return (
    <View key={key} style={{ marginVertical: 6, gap: 4 }}>
      {items.map((item, i) => (
        <View key={i} style={{ flexDirection: 'row', paddingLeft: 8 }}>
          <Text style={[bodyText(ctx.theme), { width: 24 }]}>{ordered ? `${i + 1}.` : '•'}</Text>
          <Text style={[bodyText(ctx.theme), { flex: 1 }]}>
            {renderInlineNodes(itemInlines(item), ctx)}
          </Text>
        </View>
      ))}
    </View>
  )
}

const numberedList: Render = (b, ctx, key) => list({ ...b, ordered: true }, ctx, key)

/* callout */

function calloutTone(theme: Theme, tone: unknown): string {
  switch (str(tone)) {
    case 'success':
      return theme.success
    case 'warning':
      return '#c98a1b'
    case 'danger':
      return theme.danger
    case 'neutral':
      return theme.textMuted
    default:
      return theme.accent // info
  }
}

const callout: Render = (b, ctx, key) => {
  const tone = calloutTone(ctx.theme, b.tone)
  const title = str(b.title)
  // A collapsible callout renders OPEN with its body visible — the same
  // posture as the reference's no-JS degrade (every panel visible pre-
  // hydration); v1 mobile ships no collapse interaction.
  return (
    <View
      key={key}
      style={{
        borderLeftWidth: 3,
        borderLeftColor: tone,
        backgroundColor: ctx.theme.surface,
        borderRadius: 6,
        padding: 12,
        marginVertical: 8,
      }}
    >
      {title !== '' && (
        <Text style={{ fontWeight: '700', color: ctx.theme.text, marginBottom: 4, fontSize: 14 }}>
          {title}
        </Text>
      )}
      <Text style={[bodyText(ctx.theme), { fontSize: 15, lineHeight: 23 }]}>
        {renderInlineNodes(paragraphInline(b), ctx)}
      </Text>
    </View>
  )
}

/* code / divider / image */

const code: Render = (b, ctx, key) => (
  <ScrollView
    key={key}
    horizontal
    style={{
      backgroundColor: ctx.theme.surface,
      borderLeftWidth: 3,
      borderLeftColor: ctx.theme.accent,
      marginVertical: 10,
    }}
    contentContainerStyle={{ padding: 12 }}
  >
    <Text style={{ fontFamily: MONO, fontSize: 13, lineHeight: 20, color: ctx.theme.text }}>
      {str(b.value)}
    </Text>
  </ScrollView>
)

const divider: Render = (_b, ctx, key) => (
  <View key={key} style={{ alignItems: 'center', marginVertical: 18 }}>
    <View style={{ height: 1, alignSelf: 'stretch', backgroundColor: ctx.theme.border }} />
    <Text style={{ marginTop: -11, backgroundColor: ctx.theme.bg, paddingHorizontal: 10, color: ctx.theme.textMuted }}>
      §
    </Text>
  </View>
)

const image: Render = (b, ctx, key) => {
  const src = str(b.src).trim()
  if (src === '') return null // asset-less image = editor scaffolding, skip on read
  const uri = openableUrl(src)
  if (uri === undefined) return null
  const w = num(b.width)
  const h = num(b.height)
  const ratio = w !== undefined && h !== undefined ? w / h : 16 / 9
  return (
    <Image
      key={key}
      source={{ uri }}
      accessibilityLabel={str(b.alt)}
      style={{ width: '100%', aspectRatio: ratio, borderRadius: 6, marginVertical: 8 }}
      resizeMode="contain"
    />
  )
}

/* figure / diagram — captions share the "Figure N." bold run-in law */

function figcaption(caption: string, theme: Theme, key: string | number): ReactNode {
  if (caption === '') return null
  const m = /^(Figure\s+\S+?\.)\s*([\s\S]*)$/.exec(caption)
  return (
    <Text key={key} style={{ fontSize: 13, lineHeight: 19, fontStyle: 'italic', color: theme.textMuted, marginTop: 6 }}>
      {m ? (
        <>
          <Text style={{ fontWeight: '700' }}>{m[1]}</Text>
          {m[2] !== '' ? ' ' + m[2] : ''}
        </>
      ) : (
        caption
      )}
    </Text>
  )
}

const figure: Render = (b, ctx, key) => {
  const child = b.child
  return (
    <View key={key} style={{ marginVertical: 12 }}>
      {isMap(child) ? renderBlockNative(child as Block, ctx, 0) : null}
      {figcaption(str(b.caption), ctx.theme, 'cap')}
    </View>
  )
}

const diagram: Render = (b, ctx, key) => (
  <View key={key} style={{ marginVertical: 12 }}>
    <MermaidIsland source={str(b.source)} theme={ctx.theme} />
    {figcaption(str(b.caption), ctx.theme, 'cap')}
  </View>
)

/* table — head/header alias + rows; cells are inline arrays or scalars */

const table: Render = (b, ctx, key) => {
  const headRaw = b.head ?? b.header
  const head = Array.isArray(headRaw) ? headRaw : []
  const rows = asList(b.rows)
  const cellMin = 96
  return (
    <ScrollView key={key} horizontal style={{ marginVertical: 10 }}>
      <View style={{ borderWidth: 1, borderColor: ctx.theme.border, borderRadius: 6 }}>
        {head.length > 0 && (
          <View style={{ flexDirection: 'row', backgroundColor: ctx.theme.surface }}>
            {head.map((cell, i) => (
              <View key={i} style={{ minWidth: cellMin, maxWidth: 220, padding: 8 }}>
                <Text style={{ fontWeight: '700', fontSize: 13, color: ctx.theme.text }}>
                  {renderInlineNodes(Array.isArray(cell) ? cell : [cell], ctx)}
                </Text>
              </View>
            ))}
          </View>
        )}
        {rows.map((row, ri) => (
          <View
            key={ri}
            style={{ flexDirection: 'row', borderTopWidth: 1, borderTopColor: ctx.theme.border }}
          >
            {asList(row).map((cell, ci) => (
              <View key={ci} style={{ minWidth: cellMin, maxWidth: 220, padding: 8 }}>
                <Text style={{ fontSize: 13, lineHeight: 19, color: ctx.theme.text }}>
                  {renderInlineNodes(Array.isArray(cell) ? cell : [cell], ctx)}
                </Text>
              </View>
            ))}
          </View>
        ))}
      </View>
    </ScrollView>
  )
}

/* toc — static author-supplied outline (items/depth/numbered) */

interface TocItem {
  text: string
  level: number
}

function tocItems(raw: unknown): TocItem[] {
  const out: TocItem[] = []
  for (const it of asList(raw)) {
    if (!isMap(it)) continue
    const text = str(it.text)
    if (text === '') continue
    const n = num(it.level)
    out.push({ text, level: n !== undefined ? n : 1 })
  }
  return out
}

const toc: Render = (b, ctx, key) => {
  const items = tocItems(b.items)
  if (items.length === 0) return null
  const depthRaw = num(b.depth)
  const depth = depthRaw !== undefined ? depthRaw : 2
  const numbered = b.numbered === true
  const minLevel = Math.min(...items.map((i) => i.level))
  const counters = new Array(depth + 1).fill(0) as number[]
  const rows: ReactNode[] = []
  items.forEach((item, idx) => {
    const rel = item.level - minLevel + 1
    if (rel > depth) return
    counters[rel] = (counters[rel] ?? 0) + 1
    for (let lvl = rel + 1; lvl <= depth; lvl++) counters[lvl] = 0
    const prefix = numbered ? counters.slice(1, rel + 1).join('.') + '. ' : ''
    rows.push(
      <Text
        key={idx}
        style={{
          fontSize: 14,
          lineHeight: 24,
          color: ctx.theme.accent,
          paddingLeft: (rel - 1) * 16,
        }}
      >
        {prefix + item.text}
      </Text>,
    )
  })
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 12,
        marginVertical: 10,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {rows}
    </View>
  )
}

/* stats / stat-grid / stat (dataviz.ts twins — value/denom/label/max bar;
 * sparklines are omitted honestly: no SVG dependency in v1) */

function statCard(item: Record<string, unknown>, ctx: BlockCtx, key: number): ReactNode {
  const value = str(item.value)
  if (value === '') return null
  const denom = str(item.denom)
  const label = str(item.label)
  const max = num(item.max)
  const nv = num(value)
  const pct = max !== undefined && max > 0 && nv !== undefined ? Math.min(nv / max, 1) : undefined
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 12,
        marginVertical: 4,
        backgroundColor: ctx.theme.surface,
        gap: 4,
      }}
    >
      {pct !== undefined && (
        <View style={{ height: 4, borderRadius: 2, backgroundColor: ctx.theme.border }}>
          <View
            style={{
              height: 4,
              borderRadius: 2,
              width: `${Math.round(pct * 100)}%`,
              backgroundColor: ctx.theme.accent,
            }}
          />
        </View>
      )}
      <Text style={{ fontSize: 24, fontWeight: '700', color: ctx.theme.text }}>
        {value}
        {denom !== '' && <Text style={{ fontSize: 15, color: ctx.theme.textMuted }}>/{denom}</Text>}
      </Text>
      {label !== '' && (
        <Text style={{ fontSize: 12, lineHeight: 17, color: ctx.theme.textMuted }}>{label}</Text>
      )}
    </View>
  )
}

const stat: Render = (b, ctx, key) => statCard(b, ctx, key)

const stats: Render = (b, ctx, key) => {
  const items = asList(b.items).filter(isMap)
  if (items.length === 0) return emptyDataviz('stats', ctx, key)
  return <View key={key} style={{ marginVertical: 6 }}>{items.map((it, i) => statCard(it, ctx, i))}</View>
}

function emptyDataviz(kind: string, ctx: BlockCtx, key: number): ReactNode {
  return (
    <Text key={key} style={{ fontSize: 13, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 6 }}>
      {kind} — no data
    </Text>
  )
}

/* note / notes (label + lead + text) */

function noteRow(item: unknown, ctx: BlockCtx, key: number): ReactNode {
  const m = isMap(item) ? item : {}
  const label = str(m.label)
  const lead = str(m.lead).trim()
  const text = str(m.text)
  return (
    <View key={key} style={{ flexDirection: 'row', gap: 10, marginVertical: 4 }}>
      {label !== '' && (
        <Text
          style={{
            fontSize: 12,
            fontWeight: '700',
            color: ctx.theme.accent,
            minWidth: 44,
            marginTop: 2,
          }}
        >
          {label}
        </Text>
      )}
      <Text style={{ flex: 1, fontSize: 14, lineHeight: 21, color: ctx.theme.text }}>
        {lead !== '' && <Text style={{ fontWeight: '700' }}>{lead + ' '}</Text>}
        {text}
      </Text>
    </View>
  )
}

const note: Render = (b, ctx, key) => noteRow(b, ctx, key)

const notes: Render = (b, ctx, key) => {
  const items = asList(b.items)
  if (items.length === 0) return null
  return <View key={key} style={{ marginVertical: 6 }}>{items.map((it, i) => noteRow(it, ctx, i))}</View>
}

/* cards (items title/text/tone) */

const cards: Render = (b, ctx, key) => {
  const items = asList(b.items)
  if (items.length === 0) return null
  return (
    <View key={key} style={{ marginVertical: 6, gap: 8 }}>
      {items.map((it, i) => {
        const m = isMap(it) ? it : {}
        const title = str(m.title)
        const text = str(m.text)
        return (
          <View
            key={i}
            style={{
              borderWidth: 1,
              borderColor: ctx.theme.border,
              borderRadius: 8,
              padding: 12,
              backgroundColor: ctx.theme.surface,
              gap: 4,
            }}
          >
            {title !== '' && <Text style={{ fontWeight: '700', fontSize: 14, color: ctx.theme.text }}>{title}</Text>}
            {text !== '' && <Text style={{ fontSize: 13, lineHeight: 19, color: ctx.theme.textMuted }}>{text}</Text>}
          </View>
        )
      })}
    </View>
  )
}

/* steps — numbered procedure, blocks recursed */

const steps: Render = (b, ctx, key) => {
  const rows = asList(b.steps).filter(isMap)
  if (rows.length === 0) return null
  return (
    <View key={key} style={{ marginVertical: 6, gap: 10 }}>
      {rows.map((s, i) => {
        const title = str(s.title)
        const blocks = asList<Block>(s.blocks ?? s.children)
        if (title === '' && blocks.length === 0) return null
        return (
          <View key={i} style={{ flexDirection: 'row', gap: 10 }}>
            <Text style={{ fontWeight: '700', fontSize: 15, color: ctx.theme.accent, minWidth: 22 }}>
              {i + 1}.
            </Text>
            <View style={{ flex: 1 }}>
              {title !== '' && (
                <Text style={{ fontWeight: '700', fontSize: 15, color: ctx.theme.text }}>{title}</Text>
              )}
              {blocks.map((child, ci) => renderBlockNative(child, ctx, ci))}
            </View>
          </View>
        )
      })}
    </View>
  )
}

/* expandable — summary + children, rendered OPEN (the reference's no-JS
 * degrade posture: every panel visible; v1 ships no collapse interaction) */

const expandable: Render = (b, ctx, key) => {
  const summary = str(b.summary)
  const blocks = asList<Block>(b.blocks ?? b.children)
  if (summary === '' && blocks.length === 0) return null
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 12,
        marginVertical: 8,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {summary !== '' && (
        <Text style={{ fontWeight: '700', fontSize: 14, color: ctx.theme.text, marginBottom: 4 }}>
          {summary}
        </Text>
      )}
      {blocks.map((child, i) => renderBlockNative(child, ctx, i))}
    </View>
  )
}

/* blockquote / quote — content||text body + cite */

const blockquote: Render = (b, ctx, key) => {
  const cite = str(b.cite) || str(b.attribution)
  return (
    <View
      key={key}
      style={{
        borderLeftWidth: 3,
        borderLeftColor: ctx.theme.border,
        paddingLeft: 14,
        marginVertical: 10,
      }}
    >
      <Text style={[bodyText(ctx.theme), { fontStyle: 'italic' }]}>
        {renderInlineNodes(paragraphInline(b), ctx)}
      </Text>
      {cite !== '' && (
        <Text style={{ fontSize: 13, color: ctx.theme.textMuted, marginTop: 4 }}>— {cite}</Text>
      )}
    </View>
  )
}

/* footnote — numbered reference apparatus */

const footnote: Render = (b, ctx, key) => {
  const rows = asList(b.notes)
    .filter(isMap)
    .filter((n) => str(n.text) !== '')
  if (rows.length === 0) return null
  return (
    <View key={key} style={{ marginVertical: 8, gap: 4 }}>
      {rows.map((n, i) => (
        <View key={i} style={{ flexDirection: 'row', gap: 8 }}>
          <Text style={{ fontSize: 12, color: ctx.theme.textMuted, marginTop: 2 }}>{i + 1}.</Text>
          <Text style={{ flex: 1, fontSize: 13, lineHeight: 19, color: ctx.theme.textMuted }}>
            {str(n.text)}
          </Text>
        </View>
      ))}
    </View>
  )
}

/* section / columns / terminal — containers; phone width stacks children */

const section: Render = (b, ctx, key) => {
  const blocks = asList<Block>(b.blocks)
  const title = b.title != null ? str(b.title) : ''
  return (
    <View key={key} style={{ marginVertical: 10 }}>
      <View style={{ height: 1, backgroundColor: ctx.theme.border, marginBottom: 8 }} />
      {title !== '' && (
        <Text style={{ fontWeight: '700', fontSize: 15, color: ctx.theme.text, marginBottom: 4 }}>
          {title}
        </Text>
      )}
      {blocks.map((child, i) => renderBlockNative(child, ctx, i))}
      <View style={{ height: 1, backgroundColor: ctx.theme.border, marginTop: 8 }} />
    </View>
  )
}

// Columns stack VERTICALLY on a phone — the grid geometry is a wide-surface
// affordance; the traversal (each column's blocks recursed in order) is what
// the reference law prescribes.
const columns: Render = (b, ctx, key) => {
  const cols = asList(b.columns)
  return (
    <View key={key} style={{ marginVertical: 6, gap: 8 }}>
      {cols.map((col, i) => (
        <View key={i}>{asList<Block>(col).map((child, ci) => renderBlockNative(child, ctx, ci))}</View>
      ))}
    </View>
  )
}

const terminal: Render = (b, ctx, key) => {
  const title = str(b.title)
  const footer = str(b.footer)
  const kids = asList<Block>(b.children ?? b.blocks)
  return (
    <View key={key} style={{ borderRadius: 8, overflow: 'hidden', marginVertical: 10, backgroundColor: '#15211d' }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', padding: 8, gap: 8, backgroundColor: '#0c1512' }}>
        <Text style={{ color: '#55635e', fontSize: 12 }}>●●●</Text>
        {title !== '' && <Text style={{ color: '#93a198', fontSize: 12, fontFamily: MONO }}>{title}</Text>}
      </View>
      <View style={{ padding: 10 }}>
        {kids.map((child, i) =>
          renderBlockNative(child, ctx, i),
        )}
      </View>
      {footer !== '' && (
        <Text style={{ color: '#93a198', fontSize: 11, padding: 8, paddingTop: 0 }}>{footer}</Text>
      )}
    </View>
  )
}

/* task-list / tasks — snapshot rows (Components.tasks_html twin). The
 * capstone's task-list is QUERY-driven with no snapshot: that renders the
 * same honest "No tasks yet." empty state the reference emits. */

const TASK_GLYPH: Record<string, string> = {
  open: '○',
  ready: '○',
  in_progress: '◐',
  blocked: '!',
  done: '✓',
  closed: '✓',
  cancelled: '✕',
  considering: '◌',
  researching: '◎',
}

const taskList: Render = (b, ctx, key) => {
  const rows = asList(b.snapshot).filter(isMap)
  if (rows.length === 0) {
    return (
      <Text key={key} style={{ fontSize: 13, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 8 }}>
        No tasks yet.
      </Text>
    )
  }
  const title = str(b.title).trim()
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 10,
        marginVertical: 8,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {title !== '' && (
        <Text style={{ fontWeight: '700', fontSize: 14, color: ctx.theme.text, marginBottom: 6 }}>{title}</Text>
      )}
      {rows.map((r, i) => {
        const status = str(r.status)
        const glyph = TASK_GLYPH[status] ?? (status === '' ? '○' : '◦')
        const done = status === 'done' || status === 'closed'
        return (
          <View key={i} style={{ flexDirection: 'row', gap: 8, marginVertical: 2 }}>
            <Text style={{ color: done ? ctx.theme.success : ctx.theme.textMuted, fontSize: 14 }}>{glyph}</Text>
            <Text style={{ flex: 1, fontSize: 14, lineHeight: 20, color: ctx.theme.text }}>{str(r.title)}</Text>
          </View>
        )
      })}
    </View>
  )
}

/* action — a tappable link button */

const action: Render = (b, ctx, key) => {
  const label = str(b.label)
  if (label === '') return null
  return (
    <Text
      key={key}
      style={{
        color: ctx.theme.accent,
        fontWeight: '700',
        fontSize: 15,
        textDecorationLine: 'underline',
        marginVertical: 6,
      }}
    >
      {label}
    </Text>
  )
}

/* ── unknown-block degrade — honest, labeled, logged ONCE per type ──────────── */

const warnedTypes = new Set<string>()

/** Test seam: reset the once-per-type unknown-block log. */
export function resetUnknownBlockLog(): void {
  warnedTypes.clear()
}

function unknownBlock(type: string, ctx: BlockCtx, key: number): ReactNode {
  const label = type === '' ? 'untyped block' : type
  if (!warnedTypes.has(label)) {
    warnedTypes.add(label)
    console.warn(`[barkpark-mobile] paper renderer: unsupported block type "${label}" — rendering labeled fallback`)
  }
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderStyle: 'dashed',
        borderColor: ctx.theme.border,
        borderRadius: 6,
        padding: 10,
        marginVertical: 6,
      }}
    >
      <Text style={{ fontSize: 12, color: ctx.theme.textMuted, fontStyle: 'italic' }}>
        Unsupported block: {label}
      </Text>
    </View>
  )
}

/* ── the dispatcher ─────────────────────────────────────────────────────────── */

export const BLOCK_RENDERERS: Record<string, Render> = {
  heading,
  paragraph,
  eyebrow,
  byline,
  ingress,
  pullquote,
  list,
  // authoring-drift aliases (the compose.ex / blocks/core.ts choke point)
  bulletList: list,
  bullet_list: list,
  'bulleted-list': list,
  bulleted_list: list,
  numbered_list: numberedList,
  callout,
  code,
  divider,
  image,
  figure,
  diagram,
  table,
  toc,
  stat,
  stats,
  'stat-grid': stats,
  note,
  notes,
  cards,
  steps,
  expandable,
  blockquote,
  quote: blockquote,
  footnote,
  section,
  columns,
  terminal,
  tasks: taskList,
  'task-list': taskList,
  action,
}

/** Render one type-keyed block to a ReactNode. Unknown/malformed blocks
 * degrade to the labeled fallback — never a throw, never a silent hole
 * (registry.ts renderBlock twin). */
export function renderBlockNative(block: unknown, ctx: BlockCtx, key: number): ReactNode {
  if (!isMap(block)) return unknownBlock('invalid block', ctx, key)
  const type = str(block.type)
  const render = BLOCK_RENDERERS[type]
  if (render) {
    try {
      return render(block as Block, ctx, key)
    } catch (err) {
      // A malformed instance of a known type must not take the reader down.
      console.warn(`[barkpark-mobile] paper renderer: "${type}" block failed to render:`, String(err))
      return unknownBlock(type, ctx, key)
    }
  }
  return unknownBlock(type, ctx, key)
}
