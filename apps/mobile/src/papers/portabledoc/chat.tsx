// The six typed chat-* block renderers — the RN sibling of the SAME dual-
// surface PortableDoc block types Studio and the Go TUI already draw:
//
//   chat-tool-diff · chat-todo · chat-thinking   (the inert rows, charter D25)
//   chat-approval  · chat-question · chat-plan   (the interactive cards, D35)
//
// The attr source of truth is api/lib/barkpark/portable_doc/render/components.ex
// (chat_*_block/1 builders + chat_*_html/1 emitters); the siblings are
// internal/pdrender/chat_blocks.go and js/packages/react/src/blocks/chat.ts.
// Like blocks.tsx this mirrors TRAVERSAL SEMANTICS, not DOM output — which
// fields each type reads, the defaults, the glyph vocabulary and the fold
// budget — because the react twin emits HTML strings for
// dangerouslySetInnerHTML and cannot be imported.
//
// TWO laws hold everywhere below:
//
//   1. NO DIFF ENGINE. The server ran TextDiff.diff_lines/2 once and carries
//      the derived `lines:[{op,text}]` on the block. We render THOSE. Porting
//      react's re-derived DP-LCS would fork a fourth diff engine, and a mobile
//      re-derivation could disagree with the row Studio shows.
//   2. NO HOOKS. Every renderer is a pure function of (block, ctx, key) so the
//      jest suite walks the element trees without a native host — the same
//      contract blocks.tsx keeps. The fold is therefore the HONEST STATIC fold
//      the terminal already ships (a budget-capped hunk + "… +N more lines"),
//      not a tap-to-expand control; the full input is never lost (the store
//      keeps it, a reopened session replays it whole).
import type { ReactNode } from 'react'
import { ScrollView, Text, View } from 'react-native'

import type { Theme } from '../../ui/theme'
import { roles, scale } from '../../ui/typography'
// TYPE-ONLY, so the blocks.tsx ↔ chat.tsx edge is one-directional at RUNTIME:
// blocks.tsx imports CHAT_RENDERERS, this side imports nothing but erased types.
import type { Render } from './blocks'
import { asList, isMap, str, type Block } from './model'

const MONO = 'monospace'
/** The mono measure every chat row speaks — one step under the 16/26 prose
 * register so a tool row reads as apparatus, not as the answer. It IS the
 * chrome scale's `sm` step: S8 folded the hand-typed 13/19 onto the token,
 * which tightens the lead by 1px and makes the transcript's rows agree with
 * the reader's captions instead of missing them by one. */
const ROW = scale.sm

/**
 * Lines drawn before a diff folds behind an honest overflow footnote. THE
 * SHARED CONSTANT: components.ex `@chat_diff_budget 20`,
 * chat_tool_renderer.ex `@collapsed_budget`, chat_blocks.go `chatDiffBudget`,
 * chat.ts `CHAT_DIFF_BUDGET`. Mobile is the fifth hand-synced copy — the
 * golden fixture test is the drift tripwire.
 */
export const CHAT_DIFF_BUDGET = 20

/* ── chat-tool-diff ─────────────────────────────────────────────────────────── */

/** The mutated file path, read tolerantly: the generator's fixture carries a
 * flat `path`, but the LIVE controller (chat_tool_diff_block) nests the whole
 * tool call under `input`, so the path arrives as `input.file_path`. Mirrors
 * chat_blocks.go chatDiffPath — without the nested fallback the diff header is
 * path-less on real /v1/chat data. */
export function chatDiffPath(b: Block): string {
  const flat = str(b.path)
  if (flat !== '') return flat
  const input = b.input
  if (isMap(input)) {
    const fp = str(input.file_path)
    return fp !== '' ? fp : str(input.path)
  }
  return ''
}

interface DiffLine {
  op: string
  text: string
}

function diffLines(b: Block): DiffLine[] {
  return asList(b.lines)
    .filter(isMap)
    .map((l) => ({ op: str(l.op), text: str(l.text) }))
}

function countOp(lines: DiffLine[], op: string): number {
  return lines.filter((l) => l.op === op).length
}

/** Drawable (non-gap) lines — the denominator the budget folds against
 * (chat_blocks.go diffOverflow). A `gap` is a hunk separator rule, not a line
 * of code, so it never spends budget. */
function drawableCount(lines: DiffLine[]): number {
  return lines.filter((l) => l.op !== 'gap').length
}

function diffLineStyle(op: string, theme: Theme): { prefix: string; color: string; bg?: string } {
  switch (op) {
    case '+':
      return { prefix: '+ ', color: theme.success, bg: theme.successSoft }
    case '-':
      return { prefix: '- ', color: theme.danger, bg: theme.dangerSoft }
    default:
      // An unknown op degrades to the context rendering rather than vanishing.
      return { prefix: '  ', color: theme.textMuted }
  }
}

const chatToolDiff: Render = (b, ctx, key) => {
  const theme = ctx.theme
  const lines = diffLines(b)
  const declaredAdded = intAttr(b.added)
  const declaredRemoved = intAttr(b.removed)
  const added = declaredAdded ?? countOp(lines, '+')
  const removed = declaredRemoved ?? countOp(lines, '-')
  const path = chatDiffPath(b)

  // The budget is DRAWABLE-ONLY on every surface (charter D40): a gap hunk
  // separator never spends budget, and never draws once the budget is spent —
  // a rule introducing rows the fold already discarded would be chrome for
  // nothing (the terminal twin skips it the same way).
  const rows: ReactNode[] = []
  let shown = 0
  lines.forEach((ln, i) => {
    if (shown >= CHAT_DIFF_BUDGET) return
    if (ln.op === 'gap') {
      rows.push(
        <View
          key={`g${i}`}
          style={{ height: 1, backgroundColor: theme.border, marginVertical: 4, minWidth: 120 }}
        />,
      )
      return
    }
    const s = diffLineStyle(ln.op, theme)
    rows.push(
      <Text
        key={i}
        style={{
          ...roles.chatApparatus,
          fontFamily: MONO,
          color: s.color,
          backgroundColor: s.bg,
        }}
      >
        {s.prefix + ln.text}
      </Text>,
    )
    shown++
  })

  const overflow = drawableCount(lines) - CHAT_DIFF_BUDGET

  return (
    <View
      key={key}
      style={{
        backgroundColor: theme.codeBg,
        borderRadius: 8,
        paddingHorizontal: 10,
        paddingVertical: 8,
        marginVertical: 4,
      }}
    >
      <View style={{ flexDirection: 'row', alignItems: 'baseline', gap: 8, marginBottom: 4 }}>
        {path !== '' && (
          <Text
            numberOfLines={1}
            style={{ ...scale.xs, flexShrink: 1, fontFamily: MONO, fontWeight: '700', color: theme.text }}
          >
            {path}
          </Text>
        )}
        <Text style={{ ...scale.xs, fontFamily: MONO, color: theme.success }}>
          {'+' + added}
          <Text style={{ color: theme.textMuted }}>{' '}</Text>
          <Text style={{ color: theme.danger }}>{'−' + removed}</Text>
        </Text>
      </View>
      {/* A code diff must never re-wrap — that breaks column alignment — so the
          body scrolls sideways instead (the same posture as the code block). */}
      <ScrollView horizontal showsHorizontalScrollIndicator={false}>
        <View>{rows}</View>
      </ScrollView>
      {overflow > 0 && (
        <Text style={{ ...scale.micro, fontFamily: MONO, color: theme.textMuted, marginTop: 2 }}>
          {`… +${overflow} more lines`}
        </Text>
      )}
    </View>
  )
}

/** An integer attr as written, or undefined — `added`/`removed` are honest
 * server tallies and 0 is a real value (num() in model.ts rejects 0). */
function intAttr(v: unknown): number | undefined {
  return typeof v === 'number' && Number.isInteger(v) ? v : undefined
}

/* ── chat-todo ──────────────────────────────────────────────────────────────── */

/** The three-state vocabulary; anything unrecognized is pending (mirrors
 * normalize_status/1 + normalizeTodoStatus). */
export function todoStatus(v: unknown): 'pending' | 'in_progress' | 'completed' {
  const s = str(v)
  return s === 'in_progress' || s === 'completed' ? s : 'pending'
}

/** The honest tally: in-progress is NOT done, only completed counts
 * (chat_tool_renderer.todo_progress/1). */
export function todoProgress(todos: unknown[]): string {
  const done = todos.filter((t) => isMap(t) && todoStatus(t.status) === 'completed').length
  return `${done}/${todos.length} done`
}

const TODO_GLYPH: Record<string, string> = {
  completed: '☒',
  in_progress: '◐',
  pending: '☐',
}

const chatTodo: Render = (b, ctx, key) => {
  const theme = ctx.theme
  const todos = asList(b.todos)
  return (
    <View key={key} style={{ marginVertical: 4, gap: 2 }}>
      <Text style={{ fontFamily: MONO, ...ROW, color: theme.text }}>
        <Text style={{ color: theme.accent }}>●</Text>
        {' Update todos'}
        {todos.length > 0 && (
          <Text style={{ color: theme.textMuted }}>{' · ' + todoProgress(todos)}</Text>
        )}
      </Text>
      {todos.length === 0 ? (
        <Text
          style={{
            fontFamily: MONO,
            ...ROW,
            color: theme.textMuted,
            paddingLeft: 14,
          }}
        >
          ⎿ no items
        </Text>
      ) : (
        todos.map((t, i) => todoRow(t, theme, i))
      )}
    </View>
  )
}

function todoRow(t: unknown, theme: Theme, key: number): ReactNode {
  const m = isMap(t) ? t : {}
  const status = todoStatus(m.status)
  const content = str(m.content)
  // Go reads activeForm first, the Elixir block emits active_form — accept both.
  const activeForm = str(m.activeForm) !== '' ? str(m.activeForm) : str(m.active_form)
  const glyphColor =
    status === 'completed' ? theme.success : status === 'in_progress' ? theme.accent : theme.textMuted
  const textStyle =
    status === 'completed'
      ? { color: theme.textMuted, textDecorationLine: 'line-through' as const }
      : status === 'in_progress'
        ? { color: theme.accent, fontWeight: '700' as const }
        : { color: theme.text }
  return (
    <View key={key} style={{ paddingLeft: 14 }}>
      <View style={{ flexDirection: 'row', gap: 6 }}>
        <Text style={{ fontFamily: MONO, ...ROW, color: glyphColor }}>
          {TODO_GLYPH[status]}
        </Text>
        <Text style={[{ flex: 1, fontFamily: MONO, ...ROW }, textStyle]}>
          {content}
        </Text>
      </View>
      {status === 'in_progress' && activeForm !== '' && (
        <Text
          style={{
            ...roles.chatApparatus,
            fontFamily: MONO,
            color: theme.textMuted,
            paddingLeft: 20,
          }}
        >
          {'→ ' + activeForm}
        </Text>
      )}
    </View>
  )
}

/* ── chat-thinking ──────────────────────────────────────────────────────────── */

/**
 * The provenance label. LOWERCASE with a tilde — `thought for ~N tokens` — the
 * form components.ex chat_thinking_html/1 and chat.ts both emit and the
 * generator's golden projection carries (charter D30). The Go TUI's
 * "✻ Thought for N tokens" is the OUTLIER, not the reference. A frame without
 * an integer count degrades to a bare "thought", never a fabricated number.
 */
export function chatThinkingLabel(tokens: unknown): string {
  return typeof tokens === 'number' && Number.isInteger(tokens)
    ? `thought for ~${tokens} tokens`
    : 'thought'
}

const chatThinking: Render = (b, ctx, key) => (
  <Text
    key={key}
    style={{
      ...roles.chatApparatus,
      fontFamily: MONO,
      color: ctx.theme.textMuted,
      marginVertical: 4,
    }}
  >
    {'✻ ' + chatThinkingLabel(b.tokens)}
  </Text>
)

/* ── the interactive cards (chat-approval / chat-question / chat-plan) ───────── */
//
// These carry only the read-time VISUAL. A card's ANSWERABILITY lives on the
// message ENVELOPE (role + request_id + approval_status, charter D35) and is
// wired by ChatSessionScreen's CardRow, which wraps this body with the
// Allow/Deny footer. Rendering an answer control here would paint a DEAD card
// divorced from the envelope's state — so these emit no controls and no frame
// of their own (CardRow owns the frame, exactly as the TUI's cardView does).

/** The card's read-only status word (components.ex chat_status_label/1). An
 * unrecognized status passes through verbatim rather than being swallowed. */
export function chatStatusLabel(status: string): string {
  switch (status) {
    case 'allowed':
      return '✓ allowed'
    case 'denied':
      return '⊘ denied'
    case 'canceled':
      return '— canceled'
    case 'pending':
      return 'pending'
    default:
      return status
  }
}

/** Map.get/3 semantics: the default fires on an ABSENT key only, so a
 * present-but-empty value stays empty (the react twin's `== null` test). */
function attrOr(v: unknown, fallback: string): string {
  return v == null ? fallback : str(v)
}

function cardHeader(title: string, status: string, theme: Theme): ReactNode {
  return (
    <View key="h" style={{ flexDirection: 'row', alignItems: 'baseline', gap: 6 }}>
      <Text style={{ flexShrink: 1, ...ROW, fontWeight: '700', color: theme.text }}>
        {title}
      </Text>
      <Text style={{ ...scale.xs, marginLeft: 'auto', color: theme.textMuted }}>
        {chatStatusLabel(status)}
      </Text>
    </View>
  )
}

function cardBody(text: unknown, theme: Theme): ReactNode {
  const trimmed = str(text).trim()
  if (trimmed === '') return null
  return (
    <Text key="b" style={{ ...ROW, color: theme.textMuted, marginTop: 2 }}>
      {trimmed}
    </Text>
  )
}

const chatApproval: Render = (b, ctx, key) => {
  const theme = ctx.theme
  const tool = attrOr(b.tool_name, 'tool')
  const status = attrOr(b.approval_status, 'pending')
  // The Elixir title branch (NOT Go's pending-or-empty): pending → "Allow X?".
  const title = status === 'pending' ? `Allow ${tool}?` : tool
  return (
    <View key={key} style={{ gap: 2 }}>
      {cardHeader(title, status, theme)}
      {cardBody(b.summary, theme)}
    </View>
  )
}

const chatQuestion: Render = (b, ctx, key) => {
  const theme = ctx.theme
  const questions = asList(b.questions)
  const status = attrOr(b.approval_status, 'pending')
  return (
    <View key={key} style={{ gap: 2 }}>
      {cardHeader('Question', status, theme)}
      {questions.length === 0 ? (
        <Text key="e" style={{ ...ROW, color: theme.textMuted, paddingLeft: 12 }}>
          ⎿ no question
        </Text>
      ) : (
        questions.map((q, i) => questionRow(q, theme, i))
      )}
    </View>
  )
}

function questionRow(q: unknown, theme: Theme, key: number): ReactNode {
  const m = isMap(q) ? q : {}
  // The Elixir builder folds {label} option maps to bare strings; a non-string
  // entry is skipped rather than rendered as "[object Object]".
  const options = asList(m.options).filter((o): o is string => typeof o === 'string' && o !== '')
  return (
    <View key={key} style={{ marginTop: 4, gap: 2 }}>
      <Text style={{ ...ROW, color: theme.text }}>{str(m.question)}</Text>
      {options.length > 0 && (
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6, paddingLeft: 12 }}>
          {options.map((opt, i) => (
            <Text
              key={i}
              style={{
                ...roles.chatApparatus,
                color: theme.text,
                borderWidth: 1,
                borderColor: theme.border,
                borderRadius: 4,
                paddingHorizontal: 8,
                paddingVertical: 1,
              }}
            >
              {opt}
            </Text>
          ))}
        </View>
      )}
    </View>
  )
}

const chatPlan: Render = (b, ctx, key) => {
  const theme = ctx.theme
  const status = attrOr(b.approval_status, 'pending')
  return (
    <View key={key} style={{ gap: 2 }}>
      {cardHeader(attrOr(b.title, 'Proposed plan'), status, theme)}
      {cardBody(b.preview, theme)}
    </View>
  )
}

/* ── the registry slice ─────────────────────────────────────────────────────── */

/**
 * The six typed chat-* renderers, spread into BLOCK_RENDERERS by blocks.tsx so
 * they inherit the ONE dispatcher: the unknown-block degrade, the per-type
 * render guard, and the registry tripwire. Registering them here rather than
 * inline keeps the chat vocabulary in one file while the paper reader's
 * registry stays the single dispatch table.
 */
export const CHAT_RENDERERS: Record<string, Render> = {
  'chat-tool-diff': chatToolDiff,
  'chat-todo': chatTodo,
  'chat-thinking': chatThinking,
  'chat-approval': chatApproval,
  'chat-question': chatQuestion,
  'chat-plan': chatPlan,
}

/** The block types the six renderers own — the role-dispatch and coverage-floor
 * tests read THIS, never a hand-retyped list. Frozen so a consumer cannot
 * reorder it in place (an in-place `.sort()` in one test would silently
 * reorder what every later reader sees). */
export const CHAT_BLOCK_TYPES: readonly string[] = Object.freeze(Object.keys(CHAT_RENDERERS))
