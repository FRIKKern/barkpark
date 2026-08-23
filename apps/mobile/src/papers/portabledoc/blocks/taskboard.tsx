// taskboard family (charter D49): tasks / task-list (the Components.tasks_html
// twin — snapshot rows) plus `task-board` (the Components.task_board_html twin,
// charter D46c). The capstone's task-list is QUERY-driven with no snapshot: that
// renders the same honest "No tasks yet." empty state the reference emits.
//
// THE ROLE LADDER LIVES HERE, ONCE. A persisted STATUS resolves to a ROLE, and
// the role — never the raw status — carries the glyph, the label and the hue.
// The tables below are the RN copy of js/packages/react/src/inline.tsx's
// STATUS_ROLES / roleOf, whose own source of truth is
// design/status-manifest.json (the Elixir side inlines the manifest at compile
// time and cannot drift; every JS-side copy CAN).
// DRIFT GUARD: a role, glyph or label added or changed in the manifest must be
// mirrored here in lockstep. THIS COMMENT IS NOT THE GUARD — it used to be, and
// saying so was the whole defect (mob-bl-status-manifest-mobile-gate). Two real
// gates now watch this file from opposite directions, and both are proven able
// to fail by mutation:
//   • apps/mobile/__tests__/statusManifestParity.test.ts runs inside the mobile
//     jest suite, so an edit HERE reds on the mobile gate.
//   • scripts/status-manifest-check.sh Part 5b byte-checks this file from
//     doc-gates.yml, whose paths block already covers BOTH directions —
//     design/status-manifest.json by name, and this file via `**/*.tsx` — so a
//     MANIFEST edit this file does not mirror reds there.
// The one glyph that legitimately differs (`progress`) is adjudicated in the
// manifest's own `platform_overrides`, with its reason — not skipped in either
// gate, and the gates refuse an override that stops earning its exemption or
// that would let a second divergence hide behind it.
// The tables are EXPORTED for the test and for no other reason — nothing
// outside this file may render from them, because the ladder still lives here
// once.
import type { ReactNode } from 'react'
import { Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { asList, isMap, str } from '../model'
import { MONO, type BlockCtx, type Render } from '../register'

export const STATUS_TO_ROLE: Record<string, string> = {
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

export const ROLE_GLYPH: Record<string, string> = {
  open: '○',
  ready: '○',
  // The web paints `progress` as an EMPTY span whose ::before CSS-animates the
  // Braille frames. A block renderer here is pure by law (D50: no hooks), so
  // there is no animation to run and no honest way to fake one; '◐' is the
  // glyph mobile already ships for in_progress (chat.tsx's todo vocabulary),
  // so the app stays internally consistent rather than importing the web's
  // reduced-motion fallback frame.
  progress: '◐',
  blocked: '!',
  done: '✓',
  cancel: '✕',
  considering: '◌',
  researching: '◎',
  // The fail-open sentinel (D11): an unrecognized NON-EMPTY status lands here
  // with a dim neutral glyph, never masquerading as the bright `open` circle.
  unknown: '◦',
}

export const ROLE_LABEL: Record<string, string> = {
  open: 'Open',
  ready: 'Ready',
  progress: 'In progress',
  blocked: 'Blocked',
  done: 'Done',
  cancel: 'Cancelled',
  considering: 'Considering',
  researching: 'Researching',
  unknown: 'Unknown',
}

/** The board's lane roles, in white-ladder order. `cancel` is NOT a lane (it
 * folds to a tally on the web) and neither is the `unknown` sentinel — see
 * taskBoard for what happens to their rows. */
export const BOARD_ROLES: readonly string[] = [
  'open',
  'ready',
  'progress',
  'blocked',
  'done',
  'considering',
  'researching',
]

/** An absent or empty status is `open`; an unrecognized one is `unknown`
 * (react inline.tsx roleOf — DEFAULT_ROLE vs UNKNOWN_ROLE). */
export function roleOf(status: unknown): string {
  const s = str(status)
  if (s === '') return 'open'
  return STATUS_TO_ROLE[s] ?? 'unknown'
}

export function glyphOf(role: string): string {
  return ROLE_GLYPH[role] ?? ROLE_GLYPH.unknown ?? ''
}

export function labelOf(role: string): string {
  return ROLE_LABEL[role] ?? ROLE_LABEL.unknown ?? ''
}

/** The role hue, mapped from paper-surface.css's `.bp-g--<role>` rules onto the
 * mobile palette. TWO substitutions are recorded rather than invented, because
 * the theme is the only colour source and mobile's Theme has neither token:
 * `progress` takes `accent` where the web has `--st-info`, and `researching`
 * takes `accent` where the web has `--st-violet` (its one new hue). The glyphs
 * still separate them — ◐ against ◎. */
function roleColor(role: string, ctx: BlockCtx): string {
  switch (role) {
    case 'ready':
      return ctx.theme.text
    case 'progress':
    case 'researching':
      return ctx.theme.accent
    case 'blocked':
      return ctx.theme.warn
    case 'done':
      return ctx.theme.success
    default:
      // open (ink at 50%), considering (ink at 35%), cancel + unknown
      // (ink-faint) are all the muted rung on a two-tone palette.
      return ctx.theme.textMuted
  }
}

/** The lane's 3pt top rule — `.bp-board__col` is `--paper-ink-faint` by default
 * and overridden for exactly these four roles. */
function laneRule(role: string, ctx: BlockCtx): string {
  switch (role) {
    case 'ready':
      return ctx.theme.text
    case 'progress':
      return ctx.theme.accent
    case 'blocked':
      return ctx.theme.warn
    case 'done':
      return ctx.theme.success
    default:
      return ctx.theme.border
  }
}

/* ── card meta (the bp-bcard__m / bp-trow__* vocabulary) ────────────────────── */

/** `P<digits>` with the web's severity hues (`[data-p="1"]` danger, `"2"` warn,
 * everything else faint), and its `P?` fallback for a non-numeric priority. */
function priorityChip(p: unknown, ctx: BlockCtx): ReactNode {
  const s = str(p).trim()
  if (s === '') return null
  const digits = s.replace(/[^0-9]/g, '')
  const color = digits === '1' ? ctx.theme.danger : digits === '2' ? ctx.theme.warn : ctx.theme.textMuted
  return (
    <Text key="p" style={{ ...scale.micro, fontFamily: MONO, fontWeight: '700', color }}>
      {digits === '' ? 'P?' : `P${digits}`}
    </Text>
  )
}

function criteriaChip(c: unknown, ctx: BlockCtx): ReactNode {
  if (!isMap(c)) return null
  const met = c.met
  const total = c.total
  if (typeof met !== 'number' || typeof total !== 'number' || total <= 0) return null
  return (
    <Text key="c" style={{ ...scale.micro, fontFamily: MONO, color: ctx.theme.textMuted }}>
      {`${met}/${total}`}
    </Text>
  )
}

function workerChip(w: unknown, ctx: BlockCtx): ReactNode {
  const s = str(w).trim()
  if (s === '') return null
  return (
    <Text key="w" style={{ ...scale.micro, fontFamily: MONO, color: ctx.theme.accent }}>
      {s}
    </Text>
  )
}

/* ── task-board — stacked lanes ─────────────────────────────────────────────── */

/** One board card: the row's OWN glyph, its title, and its meta line.
 *
 * PLACEMENT DECOUPLES FROM STYLING (react's taskboard.ts boardCol). The glyph
 * is resolved from the ROW's status, not from the lane it was filed under, so a
 * `cancelled` or unrecognized row homed in `open` still paints ✕ / ◦ and the
 * reader can see it is not really open. For a row whose role IS a lane the two
 * coincide, so this costs nothing in the common case. */
function boardCard(row: unknown, ctx: BlockCtx, key: number): ReactNode {
  const m = isMap(row) ? row : {}
  const role = roleOf(m.status)
  const meta = [priorityChip(m.priority, ctx), criteriaChip(m.criteria, ctx), workerChip(m.worker, ctx)].filter(
    (n) => n !== null,
  )
  return (
    <View
      key={key}
      style={{
        flexDirection: 'row',
        alignItems: 'flex-start',
        gap: 7,
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 7,
        paddingVertical: 8,
        paddingHorizontal: 10,
        backgroundColor: ctx.theme.surface,
      }}
    >
      <Text style={{ ...scale.sm, fontFamily: MONO, fontWeight: '600', color: roleColor(role, ctx) }}>
        {glyphOf(role)}
      </Text>
      <View style={{ flex: 1, gap: 4 }}>
        <Text style={{ ...scale.sm, color: ctx.theme.text }}>{str(m.title)}</Text>
        {/* react's bp-bcard__m carries priority + criteria only. The worker
            joins it here per this slice's brief: a stacked lane is full-width,
            so the row that had no space in a narrow web column has it now. */}
        {meta.length > 0 && <View style={{ flexDirection: 'row', gap: 8 }}>{meta}</View>}
      </View>
    </View>
  )
}

/** One lane. The web's lane FILL is deliberately dropped: side-by-side columns
 * need a fill to separate them horizontally, but seven stacked full-width fills
 * on a 390pt column read as a stack of boxes. The role-coloured 3pt top rule +
 * uppercase label + count pill carry the lane identity instead, and the cards
 * keep the surface fill that every other mobile card block already uses. */
function lane(role: string, rows: unknown[], ctx: BlockCtx, key: number): ReactNode {
  return (
    <View key={key} style={{ marginTop: 12, borderTopWidth: 3, borderTopColor: laneRule(role, ctx), paddingTop: 8 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
        <Text style={{ ...scale.micro, fontWeight: '700', letterSpacing: 0.6, color: ctx.theme.textMuted }}>
          {labelOf(role).toUpperCase()}
        </Text>
        <Text
          style={{
            ...scale.micro,
            fontFamily: MONO,
            color: ctx.theme.textMuted,
            backgroundColor: ctx.theme.bg,
            borderRadius: 999,
            paddingHorizontal: 7,
            paddingVertical: 1,
            overflow: 'hidden',
          }}
        >
          {String(rows.length)}
        </Text>
      </View>
      <View style={{ gap: 7 }}>{rows.map((r, i) => boardCard(r, ctx, i))}</View>
    </View>
  )
}

const taskBoard: Render = (b, ctx, key) => {
  // Unresolved and empty are DIFFERENT facts. A query-driven board that never
  // resolved has no `snapshot` array at all; an empty snapshot is a board that
  // resolved to nothing. react collapses both to "No tasks yet." — the reader
  // cannot tell a broken embed from a finished one, so mobile splits them.
  if (!Array.isArray(b.snapshot)) {
    return (
      <Text
        key={key}
        style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 8 }}
      >
        [task-board — unresolved]
      </Text>
    )
  }
  const rows = asList(b.snapshot)
  if (rows.length === 0) return emptyTasks(ctx, key)

  // A ROW IS NEVER DROPPED (D46c). A role without a lane — `cancel`, or the
  // fail-open `unknown` sentinel — homes in `open`, keeping its own glyph. The
  // TUI's board resolves considering/researching and then silently drops those
  // rows (5 lanes only, filed mob-zb-bl-tui-board-thought-lanes) and Elixir
  // drops cancelled ones; react is the newest register and mobile follows it.
  const byLane = new Map<string, unknown[]>()
  for (const r of rows) {
    const role = roleOf(isMap(r) ? r.status : undefined)
    const laneRole = BOARD_ROLES.includes(role) ? role : 'open'
    const bucket = byLane.get(laneRole)
    if (bucket === undefined) byLane.set(laneRole, [r])
    else bucket.push(r)
  }

  return (
    <View key={key} style={{ marginVertical: 8 }}>
      {BOARD_ROLES.map((role, i) => {
        const laneRows = byLane.get(role)
        // Empty lanes collapse — seven headers over one card is not a board.
        return laneRows === undefined ? null : lane(role, laneRows, ctx, i)
      })}
    </View>
  )
}

/* ── tasks / task-list — the flat snapshot rows ─────────────────────────────── */

function emptyTasks(ctx: BlockCtx, key: number): ReactNode {
  return (
    <Text
      key={key}
      style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 8 }}
    >
      No tasks yet.
    </Text>
  )
}

const taskList: Render = (b, ctx, key) => {
  const rows = asList(b.snapshot).filter(isMap)
  if (rows.length === 0) return emptyTasks(ctx, key)
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
        <Text style={{ ...scale.base, fontWeight: '700', color: ctx.theme.text, marginBottom: 6 }}>{title}</Text>
      )}
      {rows.map((r, i) => {
        // The list keeps its quieter two-tone rule — done reads as achieved,
        // everything else is muted chrome. Only the BOARD spends the full
        // ladder of hues, because on the board the lane IS the information.
        const role = roleOf(r.status)
        return (
          <View key={i} style={{ flexDirection: 'row', gap: 8, marginVertical: 2 }}>
            <Text style={{ ...scale.base, color: role === 'done' ? ctx.theme.success : ctx.theme.textMuted }}>
              {glyphOf(role)}
            </Text>
            <Text style={{ flex: 1, ...scale.base, color: ctx.theme.text }}>{str(r.title)}</Text>
          </View>
        )
      })}
    </View>
  )
}

export const taskboardRenderers: Record<string, Render> = {
  'task-board': taskBoard,
  tasks: taskList,
  'task-list': taskList,
}
