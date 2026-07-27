// core-code family — the nav/code band of react's core family (charter D49):
// tabs, code-tabs, api-endpoint, filetree, diff (mob-zb-s4-navcode-natives).
// The plain `code` fence renderer lives in core-media per the D49 band split.
//
// Metro TDZ law (D49): this module imports renderBlockNative ONLY — never
// BLOCK_RENDERERS, which is a const assembled from spreads and therefore
// undefined while the family modules evaluate. `../chat` is imported for the
// ONE shared constant (CHAT_DIFF_BUDGET) and carries no runtime edge back here.
//
// TWO structural notes for this band:
//
//   1. STATE, ONCE. Every Render below stays hook-free (the contract the jest
//      suites' host-free element walk depends on); `tabs`/`code-tabs` mount
//      TabsBlock, a small useState component, exactly the way core-media
//      mounts MermaidIsland. Its PANES are passed as CHILDREN rather than as a
//      prop on purpose — see TabsBlock.
//   2. ONE HORIZONTAL SCROLLER PER ROW (D50). A code diff and a file tree must
//      not re-wrap (re-wrapping breaks column alignment and box drawing), so
//      each scrolls sideways in its own row. Nothing here wraps a child in a
//      second horizontal ScrollView: `code-tabs` panes render THROUGH the
//      registered `code` renderer, which already owns that row's scroller, and
//      the tab strip WRAPS (the web's `flex-wrap: wrap` posture) instead of
//      scrolling. Nested horizontal scrollers are an Android
//      removeClippedSubviews hazard, recorded.
import { useState, type ReactNode } from 'react'
import { Pressable, ScrollView, Text, View } from 'react-native'

import type { Theme } from '../../../ui/theme'
import { roles, scale } from '../../../ui/typography'
import { CHAT_DIFF_BUDGET } from '../chat'
import { asList, isMap, str, type Block } from '../model'
import { MONO, type Render } from '../register'
import { renderBlockNative } from '../registry'

/* ── the tab shell (tabs + code-tabs) ───────────────────────────────────────── */

interface TabsBlockProps {
  labels: string[]
  theme: Theme
  /** One pane per label, in order. CHILDREN, not a prop: a host-free element
   * walk (the jest suites here, and the crown slice's cross-surface floor)
   * recurses `props.children` and therefore sees EVERY pane's content — which
   * is precisely the reference renderer's no-JS degrade, where the markup
   * carries all panels and hydration hides the inactive ones. Passing panes as
   * a prop would have made the whole block read as EMPTY to those walkers. The
   * tab STRIP is chrome and lives inside this component, so a host-free walk
   * does not see the labels; the mounted test (coreCodeBlocks.test.tsx) is what
   * proves the strip and the switch. */
  children: ReactNode[]
}

/** The tab strip + the active pane. The one stateful leaf in this family: the
 * Render functions stay pure and this holds the selection (the MermaidIsland
 * precedent). D22's no-chrome law is TURN-level, so a tabs block still gets to
 * look like a tabs block in the chat register — the same reasoning core-media
 * records for the code slab. */
function TabsBlock({ labels, theme, children }: TabsBlockProps): ReactNode {
  const [active, setActive] = useState(0)
  // A pane count that shrank under a re-render (a streaming chat turn re-emits
  // the block) must not blank the card.
  const index = active < children.length ? active : 0
  return (
    <View
      style={{
        borderWidth: 1,
        borderColor: theme.border,
        borderRadius: 10,
        marginVertical: 12,
        overflow: 'hidden',
        backgroundColor: theme.surface,
      }}
    >
      <View
        accessibilityRole="tablist"
        style={{
          flexDirection: 'row',
          flexWrap: 'wrap',
          paddingHorizontal: 6,
          backgroundColor: theme.bg,
          borderBottomWidth: 1,
          borderBottomColor: theme.border,
        }}
      >
        {labels.map((label, i) => (
          <Pressable
            key={i}
            onPress={() => setActive(i)}
            accessibilityRole="tab"
            accessibilityLabel={label}
            accessibilityState={{ selected: i === index }}
            style={{
              minHeight: 44, // the tap-target floor, not the web strip's compact height
              justifyContent: 'center',
              paddingHorizontal: 12,
              borderBottomWidth: 2,
              borderBottomColor: i === index ? theme.accent : 'transparent',
            }}
          >
            <Text
              style={{
                ...scale.xs,
                fontFamily: MONO,
                fontWeight: i === index ? '700' : '400',
                color: i === index ? theme.text : theme.textMuted,
              }}
            >
              {label}
            </Text>
          </Pressable>
        ))}
      </View>
      {children[index]}
    </View>
  )
}

/* ── tabs ───────────────────────────────────────────────────────────────────── */

interface TabEntry {
  label: string
  blocks: Block[]
}

/** `tabs[]` → {label, blocks}. A blank label becomes the `·` placeholder
 * (tabs.go tabEntries) so the strip never carries an unlabeled, unreadable
 * tab. Empty `tabs` is the honest empty state — nothing renders. */
function tabEntries(b: Block): TabEntry[] {
  return asList(b.tabs)
    .filter(isMap)
    .map((t) => {
      const label = str(t.label).trim()
      return { label: label !== '' ? label : '·', blocks: asList<Block>(t.blocks) }
    })
}

const tabs: Render = (b, ctx, key) => {
  const entries = tabEntries(b)
  if (entries.length === 0) return null
  return (
    <TabsBlock key={key} labels={entries.map((t) => t.label)} theme={ctx.theme}>
      {entries.map((t, i) => (
        // ctx forwarded WHOLESALE (D50) — a re-minted ctx literal would drop
        // the register on every nested block in the pane.
        <View key={i} style={{ paddingHorizontal: 12, paddingVertical: 4 }}>
          {t.blocks.map((child, ci) => renderBlockNative(child, ctx, ci))}
        </View>
      ))}
    </TabsBlock>
  )
}

/* ── code-tabs ──────────────────────────────────────────────────────────────── */

interface CodeTabEntry {
  label: string
  language: string
  value: string
}

/** `tabs[]` → {label, language, value}. `value` falls back to `code` (the
 * reference's `t.value ?? t.code`); the LABEL falls back to the language before
 * the `·` placeholder — a language IS the natural name of a code pane, and the
 * terminal twin's bare `·` throws away a name a phone strip can carry. */
function codeTabEntries(b: Block): CodeTabEntry[] {
  return asList(b.tabs)
    .filter(isMap)
    .map((t) => {
      const language = str(t.language).trim()
      const label = str(t.label).trim()
      return {
        label: label !== '' ? label : language !== '' ? language : '·',
        language,
        value: str(t.value) !== '' ? str(t.value) : str(t.code),
      }
    })
}

// RECORDED NARROWING (D46's narrowing pattern): the reference's `syncKey` —
// cross-block sync, so switching one Python tab switches every Python tab on
// the page — is NOT implemented in v1. State here is per-block (TabsBlock's own
// useState). A synced switcher needs a surface-wide registry keyed by syncKey,
// i.e. a shared-state design this renderer slice has no licence to invent;
// authored content keeps working, it just switches one card at a time. The attr
// is deliberately NOT read, so there is no half-wired seam pretending
// otherwise — this comment is the record.
const codeTabs: Render = (b, ctx, key) => {
  const entries = codeTabEntries(b)
  if (entries.length === 0) return null
  return (
    <TabsBlock key={key} labels={entries.map((t) => t.label)} theme={ctx.theme}>
      {entries.map((t, i) => (
        <View key={i} style={{ paddingHorizontal: 12, paddingBottom: 4 }}>
          {t.language !== '' && (
            <Text
              style={{
                ...scale.micro,
                fontFamily: MONO,
                fontWeight: '700',
                letterSpacing: 0.6,
                textTransform: 'uppercase',
                color: ctx.theme.textMuted,
                marginTop: 8,
              }}
            >
              {t.language}
            </Text>
          )}
          {/* The pane body goes through the REGISTERED `code` renderer (the
              code_tabs.go posture, and the reference's shared codeBlockHtml)
              rather than a second code slab: one owner for the fence chrome,
              one horizontal scroller for this row, and the register follows ctx
              for free. */}
          {renderBlockNative({ type: 'code', value: t.value }, ctx, 0)}
        </View>
      ))}
    </TabsBlock>
  )
}

/* ── api-endpoint ───────────────────────────────────────────────────────────── */

/** Method tone, straight off the status palette the web surface uses
 * (paper-surface.css `.bp-api-endpoint__method--*`): GET ok, POST info, PUT and
 * PATCH warn, DELETE danger. `accent` IS mobile's info tone (the theme mints no
 * separate one); anything unrecognized stays muted rather than borrowing a
 * meaning it has not earned. */
function methodTone(theme: Theme, method: string): string {
  switch (method) {
    case 'GET':
      return theme.success
    case 'POST':
      return theme.accent
    case 'PUT':
    case 'PATCH':
      return theme.warn
    case 'DELETE':
      return theme.danger
    default:
      return theme.textMuted
  }
}

/** `required` as the reference reads it: the boolean `true`, or the STRING
 * "true" in any case (param rows arrive JSON-decoded from an authored form or
 * from a schema import). */
function paramRequired(v: unknown): boolean {
  return v === true || str(v).trim().toLowerCase() === 'true'
}

const apiEndpoint: Render = (b, ctx, key) => {
  const method = str(b.method).toUpperCase()
  const path = str(b.path)
  // No method AND no path is the honest empty state — no phantom card for a
  // block with nothing to say (the Elixir _raw clause's `""`).
  if (method === '' && path === '') return null
  const tone = methodTone(ctx.theme, method)
  const params = asList(b.params).filter(isMap)
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 10,
        marginVertical: 12,
        overflow: 'hidden',
        backgroundColor: ctx.theme.surface,
      }}
    >
      <View
        style={{
          flexDirection: 'row',
          alignItems: 'center',
          gap: 10,
          padding: 10,
          backgroundColor: ctx.theme.bg,
        }}
      >
        {method !== '' && (
          <Text
            style={{
              ...scale.xs,
              fontFamily: MONO,
              fontWeight: '700',
              letterSpacing: 0.6,
              color: tone,
              borderWidth: 1,
              borderColor: tone,
              borderRadius: 6,
              paddingHorizontal: 8,
              paddingVertical: 2,
            }}
          >
            {method}
          </Text>
        )}
        {/* The path WRAPS (the web's `overflow-wrap: anywhere`) rather than
            scrolling: a URL path has no column alignment to protect, and a
            scroller here would be this row's second one. */}
        {path !== '' && (
          <Text style={{ ...scale.sm, fontFamily: MONO, color: ctx.theme.text, flexShrink: 1 }}>
            {path}
          </Text>
        )}
      </View>
      {/* The web's 4-column params table folds to ONE ROW PER PARAM on a phone
          (the columns/steps stacking precedent): the name leads, and in/type/
          requiredness ride the meta run. `optional` is spelled out because the
          table's "Required: No" is information, not chrome. */}
      {params.map((p, i) => {
        const meta = [str(p.in), str(p.type), paramRequired(p.required) ? 'required' : 'optional']
          .filter((part) => part !== '')
          .join(' · ')
        return (
          <View
            key={i}
            style={{
              flexDirection: 'row',
              alignItems: 'baseline',
              gap: 10,
              paddingHorizontal: 10,
              paddingVertical: 7,
              borderTopWidth: 1,
              borderTopColor: ctx.theme.border,
            }}
          >
            <Text style={{ ...scale.sm, fontFamily: MONO, color: ctx.theme.text, flexShrink: 1 }}>
              {str(p.name)}
            </Text>
            <Text style={{ ...scale.xs, color: ctx.theme.textMuted, flex: 1, textAlign: 'right' }}>
              {meta}
            </Text>
          </View>
        )
      })}
    </View>
  )
}

/* ── filetree ───────────────────────────────────────────────────────────────── */

// The D78 annotation markers, in match order, with the tone the CANONICAL
// emitter gives them (core.ts FILETREE_MARKERS / components.ex
// @filetree_markers: ● ok, ○ dim, ✕ danger). The Go TUI paints ○ with the
// chrome ACCENT instead — a pre-existing divergence between the two siblings,
// recorded here; mobile follows @barkpark/react, the canonical renderer.
const FILETREE_MARKERS: readonly [string, (t: Theme) => string][] = [
  [' ● ', (t) => t.success],
  [' ○ ', (t) => t.textMuted],
  [' ✕ ', (t) => t.danger],
]

/** Split one tree line on the EARLIEST annotation separator, glyph kept in the
 * note run (the glyph is the semantic carrier; the tone is never load-bearing).
 * No marker → null, and the whole line is the path. */
function splitFiletreeNote(
  line: string,
  theme: Theme,
): { path: string; note: string; color: string } | null {
  let hit: { idx: number; glyph: string; color: string } | null = null
  for (const [glyph, tone] of FILETREE_MARKERS) {
    const idx = line.indexOf(glyph)
    if (idx !== -1 && (hit === null || idx < hit.idx)) hit = { idx, glyph, color: tone(theme) }
  }
  if (hit === null) return null
  return { path: line.slice(0, hit.idx), note: line.slice(hit.idx), color: hit.color }
}

// THE AUTHORED SHAPE is one `text` attr of VERBATIM tree lines — box glyphs
// (│ ├ └ ─) and indentation preserved exactly — plus an optional `legend` row
// (D78). The s4 brief described a recursive `items[]` tree drawn from indents
// instead; that shape exists NOWHERE: the Elixir emitter (components.ex
// filetree_html/1), the canonical JS emitter, the Go TUI and the committed
// pd-parity golden (filetree.golden.json) all read `text`/`legend` and nothing
// else. Rendering `items[]` would have drawn every live filetree block empty,
// so this follows the persisted contract and the divergence is recorded here
// rather than silently resolved.
const filetree: Render = (b, ctx, key) => {
  const text = str(b.text)
  if (text.trim() === '') return null // honest empty state, never a blank row
  const lines = text.replace(/\n+$/, '').split('\n')
  const legend = str(b.legend)
  return (
    <View
      key={key}
      style={{
        backgroundColor: ctx.theme.codeBg,
        borderRadius: 8,
        paddingHorizontal: 10,
        paddingVertical: 8,
        marginVertical: 10,
      }}
    >
      {/* Tree lines never re-wrap — a wrapped line breaks the box drawing — so
          the rows scroll sideways as ONE row-level scroller. */}
      <ScrollView horizontal showsHorizontalScrollIndicator={false}>
        <View>
          {lines.map((line, i) => {
            const split = splitFiletreeNote(line, ctx.theme)
            return (
              <Text
                key={i}
                style={{ ...roles.chatApparatus, fontFamily: MONO, color: ctx.theme.text }}
              >
                {split === null ? (
                  line
                ) : (
                  <>
                    {split.path}
                    <Text style={{ color: split.color }}>{split.note}</Text>
                  </>
                )}
              </Text>
            )
          })}
        </View>
      </ScrollView>
      {legend !== '' && (
        <Text style={{ ...scale.micro, color: ctx.theme.textMuted, marginTop: 4 }}>{legend}</Text>
      )}
    </View>
  )
}

/* ── diff ───────────────────────────────────────────────────────────────────── */

interface DiffRow {
  /** '+' | '-' | ' ' | '@' | 'file' today. Typed as a plain string so the
   * drawable-only filter below can name 'gap' — see drawableCount. */
  op: string
  text: string
}

// Metadata lines that are never a row (D77).
const DIFF_METADATA: readonly string[] = [
  'diff --git',
  'index ',
  'old mode',
  'new mode',
  'new file mode',
  'deleted file mode',
  'similarity index',
  'rename from',
  'rename to',
  'Binary files',
]

/** A `---`/`+++` header path, normalized: the git `a/`/`b/` prefixes drop and
 * `/dev/null` folds to '' so the caller can substitute the remembered old
 * path. */
function diffHeaderPath(p: string): string {
  const t = p.trim()
  if (t === '/dev/null') return ''
  if (t.startsWith('a/') || t.startsWith('b/')) return t.slice(2)
  return t
}

/** Parse VERBATIM unified-diff text into {op,text} rows — the same row shape
 * chat-tool-diff carries pre-derived, so the fold arithmetic below is shared
 * rather than re-invented (D76: differentiate the front-end, share the back-
 * end). Transliterated from internal/pdrender/diff.go parseUnifiedDiff, the
 * completest of the three siblings: it folds mode/rename/binary metadata away
 * and remembers the `--- ` path so a deletion's `+++ /dev/null` still gets an
 * honest header — both of which react's core.ts diffLineRow drops on the floor.
 * `@@` hunk headers stay VERBATIM (D77: the line numbers are load-bearing PR
 * context). Nothing is ever invented and no body line is ever dropped. */
function parseUnifiedDiffRows(text: string): DiffRow[] {
  const rows: DiffRow[] = []
  let lastFrom = ''
  for (const line of text.replace(/\n+$/, '').split('\n')) {
    if (DIFF_METADATA.some((prefix) => line.startsWith(prefix))) continue
    if (line.startsWith('--- ')) {
      lastFrom = diffHeaderPath(line.slice(4))
      continue
    }
    if (line.startsWith('+++ ')) {
      const path = diffHeaderPath(line.slice(4))
      const resolved = path !== '' ? path : lastFrom
      if (resolved !== '') rows.push({ op: 'file', text: resolved })
      continue
    }
    if (line.startsWith('@@')) rows.push({ op: '@', text: line })
    else if (line.startsWith('+')) rows.push({ op: '+', text: line.slice(1) })
    else if (line.startsWith('-')) rows.push({ op: '-', text: line.slice(1) })
    else rows.push({ op: ' ', text: line.startsWith(' ') ? line.slice(1) : line })
  }
  return rows
}

/** The DRAWABLE denominator the D40 fold counts against: a `gap` is a hunk-
 * separator rule, not a line of code, so it never spends budget and never draws
 * once the budget is spent. THE TWIN is chat.tsx's chatToolDiff loop (and
 * chat_blocks.go diffOverflow) — chat.tsx exports the shared CHAT_DIFF_BUDGET,
 * imported above, but not the loop, and chat.tsx is another slice's territory
 * this round, so the ~10 lines are DUPLICATED with the twin named rather than
 * forked silently. parseUnifiedDiffRows emits no `gap` rows (D40's confined-
 * divergence clause: the divergence is chat-tool-diff-from-MultiEdit's alone),
 * so this equals rows.length today; it is written as the filter anyway so a
 * parser that later learns to collapse hunks inherits the law instead of
 * quietly changing the fold. */
function drawableCount(rows: DiffRow[]): number {
  return rows.filter((r) => r.op !== 'gap').length
}

function diffRowStyle(op: string, theme: Theme): { prefix: string; color: string; bg?: string } {
  switch (op) {
    case '+':
      return { prefix: '+ ', color: theme.success, bg: theme.successSoft }
    case '-':
      return { prefix: '- ', color: theme.danger, bg: theme.dangerSoft }
    default:
      // '@' hunk headers and context rows share the dim two-space gutter; an
      // unknown op degrades here rather than vanishing.
      return { prefix: '  ', color: theme.textMuted }
  }
}

const diff: Render = (b, ctx, key) => {
  // The D75 `diff` attr, falling back to the starter-era `text` key so
  // round-1-born content degrades honestly instead of vanishing (diff.go's
  // attrStrFirst discipline).
  const source = str(b.diff) !== '' ? str(b.diff) : str(b.text)
  if (source.trim() === '') return null // honest empty state
  const theme = ctx.theme
  const rows = parseUnifiedDiffRows(source)
  const added = rows.filter((r) => r.op === '+').length
  const removed = rows.filter((r) => r.op === '-').length

  const body: ReactNode[] = []
  let shown = 0
  rows.forEach((r, i) => {
    if (shown >= CHAT_DIFF_BUDGET) return
    if (r.op === 'gap') {
      body.push(
        <View
          key={`g${i}`}
          style={{ height: 1, backgroundColor: theme.border, marginVertical: 4, minWidth: 120 }}
        />,
      )
      return
    }
    if (r.op === 'file') {
      // The `+++` transition's bold path sub-header — one per file section in a
      // multi-file diff (D77). It spends budget like any other drawn row.
      body.push(
        <Text
          key={i}
          style={{
            ...roles.chatApparatus,
            fontFamily: MONO,
            fontWeight: '700',
            color: theme.text,
            marginTop: 4,
          }}
        >
          {r.text}
        </Text>,
      )
      shown++
      return
    }
    const s = diffRowStyle(r.op, theme)
    body.push(
      <Text
        key={i}
        style={{
          ...roles.chatApparatus,
          fontFamily: MONO,
          color: s.color,
          backgroundColor: s.bg,
        }}
      >
        {s.prefix + r.text}
      </Text>,
    )
    shown++
  })

  const overflow = drawableCount(rows) - CHAT_DIFF_BUDGET
  const file = str(b.file)
  const lang = str(b.lang)

  return (
    <View
      key={key}
      style={{
        backgroundColor: theme.codeBg,
        borderRadius: 8,
        paddingHorizontal: 10,
        paddingVertical: 8,
        marginVertical: 10,
      }}
    >
      <View style={{ flexDirection: 'row', alignItems: 'baseline', gap: 8, marginBottom: 4 }}>
        {file !== '' && (
          <Text
            numberOfLines={1}
            style={{
              ...scale.xs,
              flexShrink: 1,
              fontFamily: MONO,
              fontWeight: '700',
              color: theme.text,
            }}
          >
            {file}
          </Text>
        )}
        {lang !== '' && <Text style={{ ...scale.xs, color: theme.textMuted }}>{lang}</Text>}
        <Text style={{ ...scale.xs, fontFamily: MONO, color: theme.success }}>
          {'+' + added}
          <Text style={{ color: theme.textMuted }}>{' '}</Text>
          <Text style={{ color: theme.danger }}>{'−' + removed}</Text>
        </Text>
      </View>
      {/* A diff must never re-wrap — that breaks column alignment — so the body
          scrolls sideways: ONE scroller for this row (the chat-tool-diff and
          code-block posture). */}
      <ScrollView horizontal showsHorizontalScrollIndicator={false}>
        <View>{body}</View>
      </ScrollView>
      {overflow > 0 && (
        <Text style={{ ...scale.micro, fontFamily: MONO, color: theme.textMuted, marginTop: 2 }}>
          {`… +${overflow} more lines`}
        </Text>
      )}
    </View>
  )
}

/* ── exports ────────────────────────────────────────────────────────────────── */

// Test seams for coreCodeBlocks.test.tsx: the diff parse front-end, the fold
// denominator and the filetree marker split are the three places a silent
// regression could hide behind a tree that still LOOKS right; TabsBlock is
// exported so the mounted switch test asserts the component the Render actually
// mounts rather than a re-implementation.
export { TabsBlock, drawableCount, parseUnifiedDiffRows, splitFiletreeNote, type DiffRow }

export const coreCodeRenderers: Record<string, Render> = {
  tabs,
  'code-tabs': codeTabs,
  'api-endpoint': apiEndpoint,
  filetree,
  diff,
}
