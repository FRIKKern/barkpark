// core-doc family — the document-apparatus band of react's core family
// (charter D49): note, notes, cards, plus the round-2 structure natives
// (status-legend, card, pipeline, stage, task-detail, roadmap — mob-zb-s3,
// charter D46/D50/D52) which land here without touching registry.tsx.
//
// Metro TDZ law (D49): this module imports renderBlockNative ONLY — never
// BLOCK_RENDERERS, which is a const assembled from spreads and therefore
// undefined while the family modules evaluate.
import type { ReactNode } from 'react'
import { ScrollView, Text, View } from 'react-native'

import type { Theme } from '../../../ui/theme'
import { scale } from '../../../ui/typography'
import { renderInlineNodes } from '../inlines'
import { asList, isMap, paragraphInline, str, type Block } from '../model'
import { MONO, bodyText, spec, type BlockCtx, type Render } from '../register'
import { renderBlockNative } from '../registry'

/* ── the status ladder (D15) — mobile's copy of the white ladder ───────────────
 *
 * HAND-COPIED from design/status-manifest.json, the same way
 * js/packages/react/src/inline.tsx STATUS_ROLES is: that file's DRIFT WARNING
 * applies verbatim here. Nine roles resolve; LEGEND_ROLES is the
 * manifest-scoped EIGHT the legend paints — the fail-open `unknown` sentinel is
 * never a real lifecycle state and stays out of the parity key.
 *
 * ONE deliberate mobile divergence: on the web the `progress` role's glyph is
 * the empty string because a CSS ::before animates the Braille frames. RN has
 * no such hook, so the spinner role paints the STATIC frame mobile already
 * ships for in_progress everywhere else (`◐` — taskboard.tsx, chat.tsx). The
 * cross-surface golden projects glyph:"" + spinner:true; realizing that as a
 * static frame is the honest native reading, not a drift.
 */

export interface StatusRole {
  role: string
  glyph: string
  spinner: boolean
  label: string
  meaning: string
}

export const STATUS_ROLES: readonly StatusRole[] = [
  { role: 'open', glyph: '○', spinner: false, label: 'open', meaning: 'backlog — not ready yet' },
  { role: 'ready', glyph: '○', spinner: false, label: 'ready', meaning: 'unchecked — claim it now' },
  { role: 'progress', glyph: '◐', spinner: true, label: 'in progress', meaning: 'being worked right now' },
  { role: 'blocked', glyph: '!', spinner: false, label: 'blocked', meaning: 'something is required first' },
  { role: 'done', glyph: '✓', spinner: false, label: 'done', meaning: 'complete' },
  { role: 'cancel', glyph: '✕', spinner: false, label: 'cancelled', meaning: 'abandoned or superseded' },
  { role: 'considering', glyph: '◌', spinner: false, label: 'considering', meaning: 'a candidate being weighed' },
  { role: 'researching', glyph: '◎', spinner: false, label: 'researching', meaning: 'under active investigation' },
  // The fail-open sentinel (D11): an UNRECOGNIZED non-empty status lands here —
  // dim and neutral, never masquerading as `open`'s bright circle.
  {
    role: 'unknown',
    glyph: '◦',
    spinner: false,
    label: 'unknown',
    meaning: 'unrecognized status — shown dim until the vocabulary catches up',
  },
] as const

const STATUS_TO_ROLE: Record<string, string> = {
  open: 'open',
  ready: 'ready',
  in_progress: 'progress',
  blocked: 'blocked',
  done: 'done',
  closed: 'done',
  cancelled: 'cancel',
  considering: 'considering',
  researching: 'researching',
}

const ROLE_BY_NAME: Record<string, StatusRole> = Object.fromEntries(
  STATUS_ROLES.map((r) => [r.role, r]),
)

/** The canonical manifest ladder — the EIGHT roles design/status-manifest.json
 * carries today, named positively (js/packages/react/src/inline.tsx
 * MANIFEST_LADDER twin). An ALLOWLIST, not a blocklist: subtracting `unknown`
 * admitted anything ELSE a future hand-edit added to STATUS_ROLES into the
 * cross-surface legend key silently, which is the one place drift must not be
 * able to enter unannounced. What is not on the manifest is not a legend row. */
const MANIFEST_LADDER: ReadonlySet<string> = new Set([
  'open',
  'ready',
  'progress',
  'blocked',
  'done',
  'cancel',
  'considering',
  'researching',
])

/** The legend key: the EIGHT canonical manifest states, byte-frozen to what the
 * Elixir StatusVocab emits. `unknown` is JS/RN-only and held out — it is not on
 * the ladder above, so the filter drops it without naming it. */
export const LEGEND_ROLES: readonly StatusRole[] = STATUS_ROLES.filter((r) => MANIFEST_LADDER.has(r.role))

/** A persisted status → its role. Absent/empty stays `open` (nothing about a
 * blank-status row changes); an unrecognized non-empty status fails open to
 * `unknown` (inline.tsx roleOf twin). */
export function roleOf(status: unknown): string {
  const s = str(status)
  if (s === '') return 'open'
  return STATUS_TO_ROLE[s] ?? 'unknown'
}

function roleRow(name: string): StatusRole {
  return ROLE_BY_NAME[name] ?? STATUS_ROLES[0]!
}

export function glyphChar(name: string): string {
  return roleRow(name).glyph
}

/** The glyph's ink. The manifest puts `blocked` in the warn family (theme.warn
 * carries that note on itself), so blocked reads amber — the danger red belongs
 * to a cancelled task. */
function roleColor(theme: Theme, name: string): string {
  switch (name) {
    case 'done':
      return theme.success
    case 'progress':
    case 'ready':
      return theme.accent
    case 'blocked':
      return theme.warn
    case 'cancel':
      return theme.danger
    default:
      return theme.textMuted
  }
}

/* ── tone (cards / card) ──────────────────────────────────────────────────────
 * The reference paints tone as a `bp-card--<tone>` class; mobile paints it as a
 * left-border tint, the device callout already uses. The four tones must be
 * VISUALLY DISTINCT — `danger` rendering identical to `info` was the live defect
 * this slice closes. An absent/unknown tone keeps the neutral frame. */

function toneTint(theme: Theme, tone: unknown): string | undefined {
  switch (str(tone)) {
    case 'info':
      return theme.accent
    case 'ok':
      return theme.success
    case 'warn':
      return theme.warn
    case 'danger':
      return theme.danger
    default:
      return undefined
  }
}

/* note / notes (label + lead + text)
 *
 * The note body takes the paragraphInline law, not a bare `text` read — the same
 * swept sibling of the heading/list content[] defect the eyebrow carried, and the
 * reference fixed it for exactly this reason (react core.ts noteItemHtml). A note
 * persisted as `{content:[…]}` rendered BLANK here. The `text` path is unchanged:
 * the fallback only fires when `content` is absent or empty, so the case rows and
 * the cross-surface notes golden stay put. */

function noteRow(item: unknown, ctx: BlockCtx, key: number): ReactNode {
  const m = isMap(item) ? item : {}
  const label = str(m.label)
  const lead = str(m.lead).trim()
  return (
    <View key={key} style={{ flexDirection: 'row', gap: 10, marginVertical: 4 }}>
      {label !== '' && (
        <Text
          style={{
            ...scale.xs,
            fontWeight: '700',
            color: ctx.theme.accent,
            minWidth: 44,
            marginTop: 2,
          }}
        >
          {label}
        </Text>
      )}
      <Text style={{ flex: 1, ...scale.base, color: ctx.theme.text }}>
        {lead !== '' && <Text style={{ fontWeight: '700' }}>{lead + ' '}</Text>}
        {renderInlineNodes(paragraphInline(m), ctx)}
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
        const tint = toneTint(ctx.theme, m.tone)
        return (
          <View
            key={i}
            style={{
              borderWidth: 1,
              borderColor: ctx.theme.border,
              borderLeftWidth: tint === undefined ? 1 : 3,
              borderLeftColor: tint ?? ctx.theme.border,
              borderRadius: 8,
              padding: 12,
              backgroundColor: ctx.theme.surface,
              gap: 4,
            }}
          >
            {title !== '' && <Text style={{ ...scale.base, fontWeight: '700', color: ctx.theme.text }}>{title}</Text>}
            {text !== '' && <Text style={{ ...scale.sm, color: ctx.theme.textMuted }}>{text}</Text>}
          </View>
        )
      })}
    </View>
  )
}

/* ── card (MODEL B) — the ONE slot-recursive structure block ───────────────────
 * Slots {media,title,body,action} hold BLOCKS, recursed in that order through
 * the shared dispatcher with `ctx` forwarded WHOLESALE (D50: a re-minted ctx
 * literal would silently drop the register, demoting a chat card's prose back
 * to the paper serif). */

function slotBlocks(b: Block, name: string): Block[] {
  if (!isMap(b.slots)) return []
  return asList<Block>(b.slots[name])
}

/** The media slot's bare-map fast path (react core.ts normalizeMedia): a slot
 * element with no `type` IS an image descriptor, so stamp the type rather than
 * letting the dispatcher degrade it to the unknown-block fallback. */
function normalizeMedia(el: unknown): unknown {
  if (isMap(el) && 'type' in el) return el
  if (isMap(el)) return { ...el, type: 'image' }
  return el
}

const card: Render = (b, ctx, key) => {
  const tint = toneTint(ctx.theme, b.tone)
  const children: unknown[] = [
    ...slotBlocks(b, 'media').map(normalizeMedia),
    ...slotBlocks(b, 'title'),
    ...slotBlocks(b, 'body'),
    ...slotBlocks(b, 'action'),
  ]
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderLeftWidth: tint === undefined ? 1 : 3,
        borderLeftColor: tint ?? ctx.theme.border,
        borderRadius: 8,
        padding: 12,
        marginVertical: 8,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {children.map((child, i) => renderBlockNative(child, ctx, i))}
    </View>
  )
}

/* ── stage / pipeline ─────────────────────────────────────────────────────────
 * A pipeline node is a SCALAR MAP, never a nested typed block, so the cell is
 * shared code rather than a recursion: `stage` is the editable per-node twin of
 * ONE cell (the Go precedent synthesizes stage blocks the same way), and
 * `pipeline` lays a row of them out with `→` separators. Phone geometry: the row
 * scrolls horizontally at a fixed cell width — stacking the nodes would destroy
 * the one thing the block says, which is ORDER. */

/** Components.pnode_source/1: `true` marks the cell as the pipeline's origin
 * (no text of its own); a non-empty string is a provenance line under the cell. */
function pnodeSource(n: Record<string, unknown>): { origin: boolean; text: string } {
  const s = n.source
  if (s === true) return { origin: true, text: '' }
  return { origin: false, text: typeof s === 'string' ? s : '' }
}

const PIPE_CELL_WIDTH = 168

function pnodeCell(n: Record<string, unknown>, ctx: BlockCtx, key: number, inPipe: boolean): ReactNode {
  const kind = str(n.kind)
  const title = str(n.title)
  const detail = str(n.detail)
  const files = str(n.files)
  const src = pnodeSource(n)
  const dim = { ...scale.micro, fontFamily: MONO, color: ctx.theme.textMuted }
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        // The origin cell wears the accent rule — the RN reading of
        // `bp-pnode--src`, which carries no text of its own.
        borderLeftWidth: src.origin ? 3 : 1,
        borderLeftColor: src.origin ? ctx.theme.accent : ctx.theme.border,
        borderRadius: 8,
        padding: 10,
        backgroundColor: ctx.theme.surface,
        gap: 2,
        ...(inPipe ? { width: PIPE_CELL_WIDTH } : { marginVertical: 8 }),
      }}
    >
      {kind !== '' && (
        <Text
          style={{
            ...scale.micro,
            fontWeight: '700',
            letterSpacing: 1,
            textTransform: 'uppercase',
            color: ctx.theme.accent,
          }}
        >
          {kind}
        </Text>
      )}
      {title !== '' && <Text style={{ ...scale.base, fontWeight: '700', color: ctx.theme.text }}>{title}</Text>}
      {detail !== '' && <Text style={{ ...scale.sm, color: ctx.theme.textMuted }}>{detail}</Text>}
      {files !== '' && <Text style={dim}>{files}</Text>}
      {src.text !== '' && <Text style={dim}>{src.text}</Text>}
    </View>
  )
}

/** A stage's field may be SCALAR or slot-materialized (the editor's twin
 * shape): a non-empty slot wins, its element children flattened to text. */
function stageField(b: Block, name: string): unknown {
  if (isMap(b.slots)) {
    const els = asList(b.slots[name])
    if (els.length > 0) return els.map((e) => (isMap(e) ? str(e.text) : str(e))).join('')
  }
  return b[name]
}

const stage: Render = (b, ctx, key) =>
  pnodeCell(
    {
      kind: stageField(b, 'kind'),
      title: stageField(b, 'title'),
      detail: stageField(b, 'detail'),
      files: b.files,
      source: b.source,
    },
    ctx,
    key,
    false,
  )

const pipeline: Render = (b, ctx, key) => {
  const nodes = asList(b.nodes)
  if (nodes.length === 0) return null
  const cells: ReactNode[] = []
  nodes.forEach((n, i) => {
    if (i > 0) {
      cells.push(
        <Text key={`arrow-${i}`} style={{ ...scale.md, color: ctx.theme.textMuted, alignSelf: 'center' }}>
          →
        </Text>,
      )
    }
    cells.push(pnodeCell(isMap(n) ? n : {}, ctx, i, true))
  })
  return (
    <ScrollView
      key={key}
      horizontal
      showsHorizontalScrollIndicator={false}
      style={{ marginVertical: 10 }}
      contentContainerStyle={{ flexDirection: 'row', alignItems: 'stretch', gap: 8 }}
    >
      {cells}
    </ScrollView>
  )
}

/* ── status-legend ────────────────────────────────────────────────────────────
 * The one renderer that takes ZERO block props: the status vocabulary IS the
 * content, which is why the cross-surface fixture's input is data-free by
 * design. Glyph · name · meaning, one row per manifest role. */

const statusLegend: Render = (_b, ctx, key) => (
  <View
    key={key}
    style={{
      borderWidth: 1,
      borderColor: ctx.theme.border,
      borderRadius: 8,
      padding: 12,
      marginVertical: 10,
      backgroundColor: ctx.theme.surface,
      gap: 6,
    }}
  >
    {LEGEND_ROLES.map((r, i) => (
      <View key={i} style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 10 }}>
        <Text style={{ ...scale.base, width: 14, textAlign: 'center', color: roleColor(ctx.theme, r.role) }}>
          {r.glyph}
        </Text>
        <Text style={{ ...scale.sm, fontWeight: '700', color: ctx.theme.text, minWidth: 82 }}>{r.label}</Text>
        <Text style={{ flex: 1, ...scale.sm, color: ctx.theme.textMuted }}>{r.meaning}</Text>
      </View>
    ))}
  </View>
)

/* ── task-detail ──────────────────────────────────────────────────────────────
 * The premium detail card: title, meta (glyph + status · P1 · kind · worker),
 * stamp, timeline, description, criteria with evidence, dependency counts, the
 * children and papers rails, labels. Section ORDER and every emptiness rule are
 * the reference's (react core.ts taskDetail / Go detail* helpers); the geometry
 * is phone-native. A title-less task is editor scaffolding and renders nothing —
 * the same call the image renderer makes for a src-less image. */

function truthy(v: unknown): boolean {
  return v === true || v === 'true' || v === 1
}

/** `1` / `"p1"` / `"P1 "` → `P1`; anything with no digits → ''. */
function priorityLabel(p: unknown): string {
  const digits = str(p).trim().replace(/[^0-9]/g, '')
  return digits === '' ? '' : 'P' + digits
}

const RAIL_CAP = 20
const PAPERS_CAP = 10

function detailLabel(text: string, ctx: BlockCtx, key: string): ReactNode {
  return (
    <Text
      key={key}
      style={{
        ...scale.micro,
        fontWeight: '700',
        letterSpacing: 1,
        textTransform: 'uppercase',
        color: ctx.theme.textMuted,
        marginTop: 8,
      }}
    >
      {text}
    </Text>
  )
}

function glyphText(role: string, ctx: BlockCtx, key?: string | number): ReactNode {
  return (
    <Text key={key} style={{ ...scale.sm, width: 14, textAlign: 'center', color: roleColor(ctx.theme, role) }}>
      {glyphChar(role)}
    </Text>
  )
}

function detailRail(rows: unknown[], label: string, ctx: BlockCtx, keyBase: string): ReactNode[] {
  if (rows.length === 0) return []
  const shown = rows.slice(0, RAIL_CAP)
  const extra = rows.length - shown.length
  const done = rows.filter((r) => roleOf(isMap(r) ? r.status : undefined) === 'done').length
  const out: ReactNode[] = [detailLabel(`${label} · ${done}/${rows.length} done`, ctx, `${keyBase}-lbl`)]
  shown.forEach((r, i) => {
    const m = isMap(r) ? r : {}
    out.push(
      <View key={`${keyBase}-${i}`} style={{ flexDirection: 'row', gap: 8, marginTop: 2 }}>
        {glyphText(roleOf(m.status), ctx)}
        <Text style={{ flex: 1, ...scale.sm, color: ctx.theme.text }}>{str(m.title)}</Text>
      </View>,
    )
  })
  if (extra > 0) {
    out.push(
      <Text key={`${keyBase}-more`} style={{ ...scale.micro, color: ctx.theme.textMuted, marginTop: 2 }}>
        … and {extra} more
      </Text>,
    )
  }
  return out
}

const taskDetail: Render = (b, ctx, key) => {
  const t = isMap(b.task) ? b.task : b
  const title = str(t.title).trim()
  if (title === '') return null
  const theme = ctx.theme
  const sections: ReactNode[] = []

  // meta — the status glyph plus the dotted identity line
  {
    const parts = [str(t.status), priorityLabel(t.priority), str(t.kind), str(t.worker)].filter((s) => s !== '')
    sections.push(
      <View key="meta" style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 4 }}>
        {glyphText(roleOf(t.status), ctx)}
        {parts.length > 0 && (
          <Text style={{ flex: 1, ...scale.sm, color: theme.textMuted }}>{parts.join(' · ')}</Text>
        )}
      </View>,
    )
  }

  // stamp
  {
    const created = str(t.created).trim()
    const updated = str(t.updated).trim()
    const line = [created !== '' ? `created ${created}` : '', updated !== '' ? `updated ${updated}` : '']
      .filter((s) => s !== '')
      .join(' · ')
    if (line !== '') {
      sections.push(
        <Text key="stamp" style={{ ...scale.micro, color: theme.textMuted, marginTop: 2 }}>
          {line}
        </Text>,
      )
    }
  }

  // timeline — the segments WRAP on a phone instead of scrolling: a lifecycle is
  // read, not scrubbed, and a wrapped row keeps every segment on screen.
  {
    const segs = asList(t.timeline)
    if (segs.length > 0) {
      const cells: ReactNode[] = []
      segs.forEach((s, i) => {
        const m = isMap(s) ? s : {}
        if (i > 0) {
          cells.push(
            <Text key={`tl-arrow-${i}`} style={{ ...scale.micro, color: theme.textMuted }}>
              →
            </Text>,
          )
        }
        cells.push(
          <View key={`tl-${i}`} style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
            {glyphText(roleOf(m.status), ctx)}
            <Text style={{ ...scale.micro, color: theme.text }}>{str(m.label)}</Text>
          </View>,
        )
      })
      sections.push(
        <View
          key="timeline"
          style={{ flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: 6, marginTop: 6 }}
        >
          {cells}
        </View>,
      )
    }
  }

  // description — the one PROSE run on the card, so it takes the register's body
  // measure rather than a chrome rung (D50).
  {
    const d = str(t.description).trim()
    if (d !== '') {
      sections.push(
        <Text key="desc" style={[bodyText(ctx), { marginTop: 6 }]}>
          {d}
        </Text>,
      )
    }
  }

  // criteria — the met tally, then a row per criterion with its evidence beneath
  {
    const items = asList(t.criteria)
    if (items.length > 0) {
      const met = items.filter((c) => truthy(isMap(c) ? c.met : false)).length
      sections.push(detailLabel(`Criteria · ${met}/${items.length}`, ctx, 'crit-lbl'))
      items.forEach((c, i) => {
        const m = isMap(c) ? c : {}
        const done = truthy(m.met)
        const text = str(m.text) !== '' ? str(m.text) : str(m.criterion)
        const evidence = str(m.evidence).trim()
        sections.push(
          <View key={`crit-${i}`} style={{ marginTop: 3 }}>
            <View style={{ flexDirection: 'row', gap: 8 }}>
              {glyphText(done ? 'done' : 'ready', ctx)}
              <Text style={{ flex: 1, ...scale.sm, color: done ? theme.textMuted : theme.text }}>{text}</Text>
            </View>
            {evidence !== '' && (
              <Text style={{ ...scale.micro, color: theme.textMuted, paddingLeft: 22 }}>↳ {evidence}</Text>
            )}
          </View>,
        )
      })
    }
  }

  // dependency counts
  {
    const blocks = typeof t.blocks === 'number' ? t.blocks : 0
    const blockedBy = typeof t.blocked_by === 'number' ? t.blocked_by : 0
    const words = [
      blocks > 0 ? `blocks ${blocks} ${blocks === 1 ? 'task' : 'tasks'}` : '',
      blockedBy > 0 ? `blocked by ${blockedBy}` : '',
    ]
      .filter((s) => s !== '')
      .join(' · ')
    if (words !== '') {
      sections.push(detailLabel('Dependencies', ctx, 'deps-lbl'))
      sections.push(
        <Text key="deps" style={{ ...scale.sm, color: theme.text, marginTop: 2 }}>
          {words}
        </Text>,
      )
    }
  }

  // children rail
  sections.push(...detailRail(asList(t.children), 'Children', ctx, 'kid'))

  // papers rail — titles only, so it carries no status tally
  {
    const rows = asList(t.papers)
      .map((p) => str(p))
      .filter((p) => p !== '')
    if (rows.length > 0) {
      const shown = rows.slice(0, PAPERS_CAP)
      const extra = rows.length - shown.length
      sections.push(detailLabel('Papers', ctx, 'papers-lbl'))
      shown.forEach((p, i) => {
        sections.push(
          <Text key={`paper-${i}`} style={{ ...scale.sm, color: theme.accent, marginTop: 2 }}>
            ▸ {p}
          </Text>,
        )
      })
      if (extra > 0) {
        sections.push(
          <Text key="papers-more" style={{ ...scale.micro, color: theme.textMuted, marginTop: 2 }}>
            … and {extra} more
          </Text>,
        )
      }
    }
  }

  // labels
  {
    const labels = asList(t.labels)
      .map((l) => str(l))
      .filter((l) => l !== '')
    if (labels.length > 0) {
      sections.push(
        <Text key="labels" style={{ ...scale.micro, color: theme.textMuted, marginTop: 8 }}>
          {labels.join(' · ')}
        </Text>,
      )
    }
  }

  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: theme.border,
        borderRadius: 10,
        padding: 14,
        marginVertical: 10,
        backgroundColor: theme.surface,
      }}
    >
      <Text style={{ ...spec(ctx).heading[3].step, fontWeight: '700', color: theme.text }}>{title}</Text>
      {sections}
    </View>
  )
}

/* ── roadmap ──────────────────────────────────────────────────────────────────
 * PHONE ALTITUDE, deliberately not a transliteration of the 547-line terminal
 * layout: a Gantt lane needs horizontal room a phone does not have. What
 * survives is what the block MEANS — the scale, the phase GROUPING (a
 * `phase_row` lane is a group header and the lanes under it are its items), the
 * per-lane span as a proportional mini-track, the status role, and the today
 * marker. The marker rides inside every track (the reference's placement), so it
 * lines up down the column. */

interface Lane {
  title: string
  role: string
  phase: boolean
  left: number
  width: number
}

/** 0..100, defaulting to 0 — NOT model.num(), which rejects 0 and so would throw
 * away every lane that starts at the left edge. */
function clampPct(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? Math.min(Math.max(v, 0), 100) : 0
}

function clampSpan(v: unknown, left: number): number {
  if (typeof v === 'number' && Number.isFinite(v)) return Math.min(Math.max(v, 1), 100 - left)
  return Math.max(1, 100 - left)
}

function roadmapLanes(raw: unknown): Lane[] {
  return asList(raw).map((r) => {
    const m = isMap(r) ? r : {}
    const left = clampPct(m.left)
    return {
      title: str(m.title),
      role: roleOf(m.status),
      phase: truthy(m.phase_row),
      left,
      width: clampSpan(m.width, left),
    }
  })
}

/** Split the lanes into phase groups: a phase lane opens a group; lanes before
 * the first phase lane form a leading headerless group. */
function roadmapGroups(lanes: Lane[]): { header?: Lane; items: Lane[] }[] {
  const groups: { header?: Lane; items: Lane[] }[] = []
  for (const lane of lanes) {
    if (lane.phase) {
      groups.push({ header: lane, items: [] })
      continue
    }
    const last = groups[groups.length - 1]
    if (last === undefined) groups.push({ items: [lane] })
    else last.items.push(lane)
  }
  return groups
}

function roadmapTrack(lane: Lane, ctx: BlockCtx, today: number | undefined): ReactNode {
  return (
    <View
      style={{ height: 6, borderRadius: 3, backgroundColor: ctx.theme.border, marginTop: 4, overflow: 'hidden' }}
    >
      <View
        style={{
          position: 'absolute',
          left: `${lane.left}%`,
          width: `${lane.width}%`,
          top: 0,
          bottom: 0,
          borderRadius: 3,
          backgroundColor: roleColor(ctx.theme, lane.role),
        }}
      />
      {today !== undefined && (
        <View
          style={{
            position: 'absolute',
            left: `${today}%`,
            top: 0,
            bottom: 0,
            width: 2,
            backgroundColor: ctx.theme.text,
          }}
        />
      )}
    </View>
  )
}

function roadmapLane(lane: Lane, ctx: BlockCtx, today: number | undefined, key: string): ReactNode {
  return (
    <View key={key} style={{ marginTop: 8, paddingLeft: lane.phase ? 0 : 12 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        {glyphText(lane.role, ctx)}
        <Text
          style={{
            flex: 1,
            ...(lane.phase ? scale.base : scale.sm),
            fontWeight: lane.phase ? '700' : '400',
            color: lane.phase ? ctx.theme.text : ctx.theme.textMuted,
          }}
        >
          {lane.title}
        </Text>
      </View>
      {roadmapTrack(lane, ctx, today)}
    </View>
  )
}

const roadmap: Render = (b, ctx, key) => {
  const lanes = roadmapLanes(b.snapshot)
  if (lanes.length === 0) {
    return (
      <Text key={key} style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 8 }}>
        No roadmap items.
      </Text>
    )
  }
  const today = typeof b.today === 'number' ? clampPct(b.today) : undefined
  const ticks = asList(b.scale)
    .map((c) => str(c))
    .filter((c) => c !== '')
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 10,
        padding: 12,
        marginVertical: 10,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {ticks.length > 0 && (
        <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
          {ticks.map((c, i) => (
            <Text key={i} style={{ ...scale.micro, color: ctx.theme.textMuted }}>
              {c}
            </Text>
          ))}
        </View>
      )}
      {today !== undefined && (
        <Text style={{ ...scale.micro, fontWeight: '700', color: ctx.theme.text, marginTop: 2 }}>
          today · {Math.round(today)}%
        </Text>
      )}
      {roadmapGroups(lanes).map((g, gi) => (
        <View key={gi} style={{ marginTop: gi === 0 ? 0 : 6 }}>
          {g.header !== undefined && roadmapLane(g.header, ctx, today, `h-${gi}`)}
          {g.items.map((lane, li) => roadmapLane(lane, ctx, today, `i-${gi}-${li}`))}
        </View>
      ))}
    </View>
  )
}

export const coreDocRenderers: Record<string, Render> = {
  note,
  notes,
  cards,
  card,
  stage,
  pipeline,
  'status-legend': statusLegend,
  'task-detail': taskDetail,
  roadmap,
}
