// taskboard family (charter D49): tasks / task-list (the Components.tasks_html
// twin — snapshot rows) plus `task-board` (the Components.task_board_html twin,
// charter D46c). The capstone's task-list is QUERY-driven with no snapshot: that
// renders the same honest "No tasks yet." empty state the reference emits.
//
// THE ROLE LADDER IS NOT TYPED HERE. It is GENERATED from
// design/status-manifest.json — the ONE source of the white ladder — into
// ./status-vocab.gen.ts by design/emit.mjs, exactly as the react and web twins
// are (js/packages/react/src/status-vocab.gen.ts, web/lib/status-ladder.gen.ts).
// This file re-exports that projection with the ONE thing the manifest does not
// own appended: the JS-only fail-open `unknown` sentinel (D11), which is never a
// lifecycle state and appears in no manifest.
//
// WHY GENERATED AND NOT GUARDED. This file used to hand-type the whole
// vocabulary behind a comment that said it was the guard; that comment was the
// defect (mob-bl-status-manifest-mobile-gate), and the byte-check that replaced
// it — scripts/status-manifest-check.sh Part 5b — was an ENUMERATION: a gate can
// only byte-check the copies it was told about, so copy #4 arrives unguarded. A
// generated projection cannot hold a value the manifest does not, for any number
// of surfaces. Three gates watch the derivation now, each catching an edit the
// others cannot see:
//   • design/check.mjs Part A (doc-gates) re-emits status-vocab.gen.ts from the
//     manifest and byte-compares the committed bytes — so a HAND-EDIT of the
//     generated file, or a manifest edit landed without a regen, reds there.
//   • scripts/status-manifest-check.sh Part 5b is now a FRESHNESS assertion: it
//     proves this file still READS the generated projection instead of retyping
//     it, and holds the manifest's platform_overrides honest.
//   • apps/mobile/__tests__/statusManifestParity.test.ts runs inside the mobile
//     jest suite and pins the resulting VALUES against the manifest on disk.
// The one glyph that legitimately differs (`progress`) is adjudicated in the
// manifest's own `platform_overrides`, with its reason, and the emitter applies
// it — so it is true by construction rather than asserted afterwards.
// The tables are EXPORTED for the test and for no other reason — nothing
// outside this file may render from them, because the ladder still resolves here
// once.
import type { ReactNode } from 'react'
import { Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { asList, isMap, str } from '../model'
import { MONO, type BlockCtx, type Render } from '../register'
import {
  MANIFEST_DEFAULT_ROLE,
  MANIFEST_ROLE_GLYPH,
  MANIFEST_ROLE_LABEL,
  MANIFEST_STATUS_TO_ROLE,
} from './status-vocab.gen'

/** The manifest `statuses` map, verbatim from the generated projection. */
export const STATUS_TO_ROLE: Record<string, string> = MANIFEST_STATUS_TO_ROLE

/** The manifest rungs' glyphs (the emitter has already applied the manifest's
 * own adjudicated `progress` override for this surface), PLUS the fail-open
 * sentinel (D11): an unrecognized NON-EMPTY status lands on a dim neutral glyph,
 * never masquerading as the bright `open` circle. The sentinel is appended here
 * because it is not a manifest rung and the generated file must not invent one.
 * Spread order keeps the manifest rungs in manifest order — BOARD_ROLES below
 * derives the lane order from exactly that. */
export const ROLE_GLYPH: Record<string, string> = {
  ...MANIFEST_ROLE_GLYPH,
  unknown: '◦',
}

/** The manifest rungs' sentence-cased labels, plus the sentinel's. */
export const ROLE_LABEL: Record<string, string> = {
  ...MANIFEST_ROLE_LABEL,
  unknown: 'Unknown',
}

/** The terminal, non-claimable rung. Named once so the lane derivation reads as a
 * RULE ("move the terminal rung last"), not as a second hand-typed list. */
export const CANCEL_ROLE = 'cancel'

/** The opacity the terminal lane renders at — the web twin's
 * `.bp-board__col--cancel { opacity: .55 }`. */
const LANE_DEEMPHASIS = 0.55

/** The JS-only fail-open sentinel (D11) — never a manifest rung, never a lane. */
const SENTINEL_ROLE = 'unknown'

/** The board's lane roles — DERIVED from ROLE_LABEL's key order, which IS
 * design/status-manifest.json's roles[] order: the generated projection emits the
 * rungs in manifest order and the sentinel is spread in last. EVERY manifest rung is a
 * lane, with the terminal `cancel` rung moved LAST and de-emphasised (see lane()).
 *
 * Before task-881952f8d8417f4b this was a hand-typed seven-role list without
 * `cancel`, so the fallback in taskBoard homed cancelled rows in `open` — the
 * CLAIMABLE lane `bp task ready` serves — manufacturing phantom ready work. With
 * every rung a lane, the only role that fallback can still catch is the sentinel.
 *
 * Deriving rather than retyping means a rung added to the manifest becomes a lane
 * automatically; it can never be silently dropped or misfiled again. */
export const BOARD_ROLES: readonly string[] = [
  ...Object.keys(ROLE_LABEL).filter((r) => r !== SENTINEL_ROLE && r !== CANCEL_ROLE),
  CANCEL_ROLE,
]

/** An absent or empty status falls back to the manifest's `default_role`; an
 * unrecognized one fails OPEN to the sentinel (react inline.tsx roleOf —
 * DEFAULT_ROLE vs UNKNOWN_ROLE). Neither value is typed here. */
export function roleOf(status: unknown): string {
  const s = str(status)
  if (s === '') return MANIFEST_DEFAULT_ROLE
  return STATUS_TO_ROLE[s] ?? SENTINEL_ROLE
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
    <View
      key={key}
      style={{
        marginTop: 12,
        borderTopWidth: 3,
        borderTopColor: laneRule(role, ctx),
        paddingTop: 8,
        // The terminal lane is DE-EMPHASISED: abandoned work stays legible but
        // does not compete with claimable work. Mirrors the web's
        // `.bp-board__col--cancel { opacity: .55 }`.
        opacity: role === CANCEL_ROLE ? LANE_DEEMPHASIS : 1,
      }}
    >
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

  // A ROW IS NEVER DROPPED (D46c) AND NEVER MISFILED. Every manifest rung has a
  // lane of its own now (task-881952f8d8417f4b), so the only role that can reach
  // the `open` fallback is the non-manifest `unknown` sentinel — a cancelled row
  // lands in the terminal `cancel` lane, last and de-emphasised, not in the
  // claimable lane. All four sibling board surfaces obey the same derived rule.
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
