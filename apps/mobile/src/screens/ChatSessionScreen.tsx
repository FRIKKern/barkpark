// One chat session — the full floor (charter crown R3): send, streamed
// assistant turns, interrupt, approve/deny. The transcript is the reducer's
// truth: settled rows (Postgres, via the turn-boundary refetch), optimistic
// local echoes (queued-badged mid-turn, D12), and the live streaming tail
// (chat-TUI charter D9). Cards (approval / plan / question) answer through
// the same allow/deny-only contract as the TUI and Studio — one row, one truth.
import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactElement } from 'react'
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native'
// There is NO root export on @legendapp/list (main/module/types are null) —
// a bare '@legendapp/list' import fails at the first build, not at runtime.
import { LegendList, type LegendListRef } from '@legendapp/list/react-native'

import type { InstanceConnection } from '../api/instance'
import {
  fetchChatCapabilities,
  type ChatCapabilities,
  type StreamFailure,
  type StreamStatus,
} from '../api/chat'
import { PickerSheet, type PickerKind } from '../chat/PickerSheet'
import { StreamSkeleton } from '../chat/StreamSkeleton'
import { tailRemainder, type StableSegment, type SuppressedRow } from '../chat/reducer'
import {
  contentMark,
  distanceFromEnd,
  FOLLOW_THRESHOLD,
  initialFollowState,
  reduceFollow,
  showJumpPill,
  type FollowState,
} from '../chat/followScroll'
import {
  foldWorkLog,
  freezeFold,
  initialWorkLogFold,
  observeGroups,
  toggleWorkLog,
  workLogExpanded,
  workLogGroups,
  workLogHeaderCache,
  workLogSummary,
  type CachedHeader,
  type WorkLogGroup,
  type WorkLogRow,
} from '../chat/workLog'
import {
  answerable,
  approvalStatus,
  isCard,
  isCardRole,
  messageBlocks,
  requestId,
  type ChatMessage,
  type StableSkeleton,
} from '../chat/wire'
import { useChatSession } from '../chat/useChatSession'
import { BLOCK_RENDERERS, DEGRADE_ONLY, renderBlockNative, type BlockCtx } from '../papers/portabledoc/blocks'
import type { Block } from '../papers/portabledoc/model'
import { haptic } from '../ui/haptics'
import { useTheme, type Theme } from '../ui/theme'
import { roles, scale } from '../ui/typography'

const CARD_TITLES: Record<string, string> = {
  approval: 'Approval requested',
  question: 'Question',
  plan: 'Plan proposed',
}

// ── header connection label (charter D24) ────────────────────────────────────

export interface HeaderStatus {
  text: string
  tone: 'muted' | 'danger'
  /** refused is actionable: 'retry' rebuilds the store (which re-reads the
   * stored token — the re-auth flow), 'back' leaves the dead session. */
  action?: 'retry' | 'back'
}

/** The label map — the raw StreamStatus enum NEVER reaches the UI. open and
 * closed render nothing (silence is the healthy state); degraded keeps the
 * transcript intact and the composer editable; refused names WHICH wall the
 * stream hit and what tapping it does. Pure, so it is jest-provable. */
export function headerStatus(
  status: StreamStatus,
  failure?: StreamFailure,
): HeaderStatus | undefined {
  switch (status) {
    case 'connecting':
      return { text: 'connecting…', tone: 'muted' }
    case 'degraded':
      return { text: 'reconnecting…', tone: 'muted' }
    case 'refused': {
      const http = failure?.httpStatus
      if (http === 401 || http === 403)
        return { text: 'signed out — sign in again', tone: 'danger', action: 'retry' }
      if (http === 404) return { text: 'session gone', tone: 'danger', action: 'back' }
      return { text: 'connection refused — tap to retry', tone: 'danger', action: 'retry' }
    }
    case 'open':
    case 'closed':
      return undefined
  }
}

/** THE RATIFIED FOLLOW CONFIG, hoisted out of the JSX so it is reachable.
 *
 * `on` is absent DELIBERATELY and that absence is load-bearing: LegendList
 * treats an omitted `on` as ALL triggers, but an explicit one as an opt-in
 * list — so writing `on: {dataChange: true, itemLayout: true}` silently drops
 * footerLayout, the re-pin that catches a row measuring LATE. MermaidIsland
 * reports its height asynchronously by postMessage, so a diagram settling
 * after layout is exactly the case that would otherwise strand the tail
 * off-screen. A config that looks more explicit would be strictly weaker,
 * which is why the absence gets a test rather than a comment alone. */
export const TRANSCRIPT_FOLLOW: { animated: boolean } = { animated: true }

/** Row height hint for the boot frame only — the measured heights replace it.
 * Sized for a short assistant paragraph, the transcript's commonest row.
 *
 * RE-DERIVED when the rhythm moved off contentContainerStyle and onto the rows
 * (TRANSCRIPT_ROW_GAP). The number an estimate has to describe is the ITEM
 * CONTAINER's height, and under the old gap that container was the row plus a
 * list-injected 18px of paddingBottom; under the new one it is the row plus its
 * own 18px lead. For every row the BOOT frame can contain those are the same
 * number, because the boot frame is settled message rows and a settled row
 * always opens a turn — so 180 still describes exactly what it described, and
 * changing it would be the drift, not keeping it. */
export const ESTIMATED_ROW_HEIGHT = 180

/** THE ONE PIECE OF GEOMETRY THE LIST NO LONGER OWNS.
 *
 * `contentContainerStyle: { gap }` is not a gap legend-list forwards. 3.3.3
 * STRIPS gap/rowGap/columnGap out of the container style (the ScrollView
 * provably receives no gap key) and re-emits the value as a border-box
 * `paddingBottom` on EVERY absolutely-positioned item container, then folds it
 * into its scroll-axis geometry. It is therefore UNIFORM BY CONSTRUCTION: every
 * row boundary pays it, including the boundaries INSIDE a single answering
 * turn — and there is no listContent edit that can tighten those alone.
 *
 * That mattered because a live turn arrives as one segment row per committed
 * segment (D59/D65) while the SAME turn cold is one row holding every block. So
 * the list-owned gap was pure ADDITION on the live side: the same turn read
 * 18px airier at every intra-turn boundary while it streamed, and snapped
 * tighter at settle — 30 live against 12 cold for two paragraphs, not a
 * replacement for the block rhythm but a second helping of it.
 *
 * So the gap comes off listContent and the rhythm is applied per row, under one
 * rule: an intra-turn boundary contributes EXACTLY ZERO extra. Never "18 less"
 * — block margins in the chat register span 2/4/6/8/10/14, so a subtraction
 * would be a different lie at every pair. Zero is the only value that makes the
 * live turn and the cold turn the same document. */
export const TRANSCRIPT_ROW_GAP = 18

export type Row =
  | { key: string; kind: 'message'; message: ChatMessage }
  /** An optimistic echo. `failed` is the honesty flag: the POST was rejected,
   * so this text is NOT on the server and the bubble must not keep wearing the
   * delivered paint. Optional because a row that says nothing about delivery
   * is, by construction, one that was never told a send failed. */
  | { key: string; kind: 'local'; content: string; queued: boolean; failed?: boolean }
  | { key: string; kind: 'tail'; text: string }
  /** A work-log disclosure header — the collapsed stand-in for a run of
   * apparatus rows (workLog.ts owns which rows those are and whether the run
   * is open; this row is only its handle). */
  | { key: string; kind: 'log'; group: WorkLogGroup; open: boolean }
  /** ONE committed segment of an answering turn, drawn as a document while the
   * rest of the answer is still arriving (charter D59/D65). Its key is
   * `s-<turn>-<from>` — the segment's wire identity — so the row survives every
   * later delta by identity and React never re-renders a paragraph the reader
   * has already finished reading. */
  | { key: string; kind: 'segment'; blocks: Block[]; opensTurn: boolean }
  /** The forming block at the head of the remainder (charter D67): the prose
   * above it keeps streaming as live text, the block itself is an honest labelled
   * placeholder until it is whole. Never fabricated content. */
  | { key: string; kind: 'skeleton'; label: string; prose: string }

/** A row's role in the persisted vocabulary. Local echoes and the streaming
 * tail are the user's and the assistant's own words respectively; the log
 * header is chrome and belongs to no role, which is exactly why it never folds
 * into a group of its own. */
export function rowRole(row: Row): string {
  switch (row.kind) {
    case 'message':
      return row.message.role
    case 'local':
      return 'user'
    case 'tail':
    // A committed segment and a forming placeholder are both the assistant
    // mid-sentence — the same turn the tail is, so they fold exactly as it does
    // (which is to say: never, because the answer is not apparatus).
    case 'segment':
    case 'skeleton':
      return 'assistant'
    case 'log':
      return 'log'
  }
}

/** The projection workLog.ts folds over — the screen's Row union stays here,
 * the pure module never learns about it. */
export function workLogRows(rows: readonly Row[]): WorkLogRow[] {
  return rows.map((row) => ({ key: row.key, role: rowRole(row) }))
}

// ── row assembly (the memo's other half) ─────────────────────────────────────
//
// These three builders exist SEPARATELY, and the screen memoizes them
// separately, for one reason: memo(TranscriptRow) is INERT unless a settled
// row's props survive a tail tick unchanged. Building every row inside one
// useMemo keyed on `state.tail` re-minted the whole array on every token
// frame, so each settled row got a brand-new `row` object and re-rendered
// anyway — the memo would have been decoration. Splitting on the reducer's own
// identity boundaries (state.messages and state.local keep their array
// identity across a delta; only state.tail changes) is what makes the
// memoization real, and assembleRows is where the law is provable.

export function messageRows(messages: readonly ChatMessage[]): Row[] {
  return messages.map((message) => ({ key: `m-${message.seq}`, kind: 'message', message }))
}

export function localRows(
  local: readonly { content: string; queued: boolean; failed?: boolean }[],
): Row[] {
  return local.map((l, i) => ({
    key: `l-${i}`,
    kind: 'local',
    content: l.content,
    queued: l.queued,
    failed: l.failed === true,
  }))
}

/** The committed segments as list rows, THROUGH A MEMO TABLE keyed on the row
 * key — a `Map`, not state and not a ref, exactly like workLogHeaderCache.
 *
 * The table is the point. `state.segments` is append-only, so re-mapping it would
 * mint a brand-new row object for every EARLIER segment on every commit, and
 * memo(TranscriptRow) reads identity: a settled paragraph would re-render two
 * times a second for the rest of the turn. With the table, a segment's row is
 * built once and handed back forever — which is what makes "a committed segment
 * never re-renders" a fact about the code rather than a hope about React.
 *
 * A segment is immutable and its key carries its turn, so a hit can never be
 * stale; entries for dropped segments are evicted so a degrade cannot leak a
 * turn's rows into the next one. */
export function stableSegmentRows(
  table: Map<string, Row>,
  segments: readonly StableSegment[],
): Row[] {
  const live = new Set<string>()
  const out: Row[] = []
  const seenTurns = new Set<number>()
  for (const seg of segments) {
    const key = `s-${seg.turn}-${seg.from}`
    live.add(key)
    // Whether this segment OPENS its turn is a fact about the ordering — the
    // first segment of a turn is the one rowLead gives the 18px turn-boundary
    // lead, every later one continues at zero — and it is stamped HERE because
    // this loop is the one place that can see it while getItemType only ever
    // receives (item, index) (mob-lm-s5f-segment-size-bucket). Stable under the
    // memo table: segments are append-only per turn and dropped wholesale, so a
    // turn's first segment stays its first and a cache hit can never carry a
    // stale answer. NOT derived from `from === 0` — a resumed stream's first
    // held segment does not start at byte 0 (see rowLead's own note).
    const opensTurn = !seenTurns.has(seg.turn)
    seenTurns.add(seg.turn)
    const hit = table.get(key)
    if (hit !== undefined) {
      out.push(hit)
      continue
    }
    const row: Row = { key, kind: 'segment', blocks: seg.blocks, opensTurn }
    table.set(key, row)
    out.push(row)
  }
  for (const key of [...table.keys()]) if (!live.has(key)) table.delete(key)
  return out
}

/** Everything the live document contributes to the list, hoisted into one shape
 * so assembleRows takes a single extra argument and the whole progressive layer
 * is one identity to memoize. */
export interface LiveDoc {
  /** The committed segment rows of every turn still being drawn from, in commit
   * order, grouped by the turn they belong to. */
  byTurn: Map<number, Row[]>
  /** Persisted rows whose content is already painted as segment rows: seq → the
   * turn that stands in for it (charter D61). */
  suppressed: readonly SuppressedRow[]
  /** The turn whose segments have not been suppressed yet — the one still
   * streaming. -1 when none. */
  liveTurn: number
  /** The plain, uncommitted remainder of the tail. */
  remainder: string
  /** The forming block at the head of that remainder, or null. */
  skeleton: StableSkeleton | null
}

/** Group segment rows by turn, reading the turn back out of the row key so the
 * grouping cannot disagree with the keys the list actually renders. */
export function groupSegmentRows(rows: readonly Row[]): Map<number, Row[]> {
  const out = new Map<number, Row[]>()
  for (const row of rows) {
    if (row.kind !== 'segment') continue
    const turn = Number(row.key.split('-')[1])
    const bucket = out.get(turn)
    if (bucket === undefined) out.set(turn, [row])
    else bucket.push(row)
  }
  return out
}

/** The answering turn a row belongs to, or undefined for a row that is not part
 * of one. Only committed SEGMENT rows can pair up INSIDE a turn: the tail and
 * the skeleton are the uncommitted edge, and the cold rendering of the turn has
 * no counterpart for them to be geometrically identical to. The turn is read
 * back out of the row key exactly as groupSegmentRows reads it, so the two
 * cannot disagree about where a turn begins. */
export function rowTurn(row: Row): number | undefined {
  if (row.kind !== 'segment') return undefined
  return Number(row.key.split('-')[1])
}

/** How much bare space precedes the row at `index` — the transcript's rhythm,
 * moved off the (uniform, and therefore wrong) contentContainerStyle gap.
 *
 * Zero at the head of the transcript, zero across an intra-turn boundary, and
 * the full TRANSCRIPT_ROW_GAP everywhere else — which is what keeps turn-to-turn
 * rhythm exactly what it has always been while the inside of a turn becomes the
 * document it is when it settles.
 *
 * Derived from the LIST, not from the row: "does this row continue the previous
 * one" is a fact about the ordering, and a segment cannot answer it alone (a
 * resumed stream's first held segment does not start at byte 0, so `from === 0`
 * would silently jam a turn against the one above it). Tolerant of a caller
 * that hands over neither — the hook-free row seam is called from jest with the
 * row alone, and a missing ordering means no claim about neighbours. */
export function rowLead(rows?: readonly Row[], index?: number): number {
  if (rows === undefined || index === undefined || index <= 0) return 0
  const row = rows[index]
  const prev = rows[index - 1]
  if (row === undefined || prev === undefined) return 0
  const turn = rowTurn(row)
  return turn !== undefined && turn === rowTurn(prev) ? 0 : TRANSCRIPT_ROW_GAP
}

/** Concatenate the pre-built halves with the live tail. The message and local
 * rows are passed through BY REFERENCE — a tail tick mints exactly one new row
 * object (the tail's) and leaves every settled row's identity alone.
 *
 * `live` is OPTIONAL, and that is the shape of the no-op: called without it —
 * which is what a server emitting no `stable` frames produces — this returns the
 * exact array it always did, one plain tail row and nothing else. The
 * progressive layer cannot degrade a stream it was never handed.
 *
 * With it, three things change and nothing else does. A suppressed persisted row
 * is REPLACED IN PLACE by the segment rows standing in for it, so the turn keeps
 * its position in the transcript. The still-streaming turn's segments sit after
 * the echoes, where the tail row used to start. And the tail row carries the
 * REMAINDER rather than the whole tail — or gives way to a placeholder row when
 * the remainder's head is a block the server says is still forming. */
export function assembleRows(settled: Row[], echoes: Row[], tail: string, live?: LiveDoc): Row[] {
  if (live === undefined) {
    const out: Row[] = [...settled, ...echoes]
    if (tail !== '') out.push({ key: 'tail', kind: 'tail', text: tail })
    return out
  }

  const standIn = new Map<number, number>()
  for (const row of live.suppressed) standIn.set(row.seq, row.turn)

  const out: Row[] = []
  for (const row of settled) {
    const turn = row.kind === 'message' ? standIn.get(row.message.seq) : undefined
    if (turn === undefined) {
      out.push(row)
      continue
    }
    // The row stays in `messages` untouched — Postgres is still the sole truth.
    // It simply is not drawn twice.
    out.push(...(live.byTurn.get(turn) ?? []))
  }
  out.push(...echoes)
  // The live turn's segments, unless this turn has already been suppressed into
  // the transcript above (which would draw it twice).
  if (live.liveTurn !== -1 && !new Set(standIn.values()).has(live.liveTurn)) {
    out.push(...(live.byTurn.get(live.liveTurn) ?? []))
  }
  if (tail !== '') {
    if (live.skeleton !== null) {
      // The placeholder REPLACES the plain tail row rather than joining it: the
      // skeleton draws its own prose (the bytes above the forming block) and the
      // block's half-written source belongs behind the box, not beside it.
      out.push({
        key: 'skeleton',
        kind: 'skeleton',
        label: live.skeleton.kind,
        prose: live.skeleton.prose,
      })
    } else {
      out.push({ key: 'tail', kind: 'tail', text: live.remainder })
    }
  }
  return out
}

// ── the two-phase floor (chat-TUI charter D8/D9) ─────────────────────────────

/** What a row's body paints: a document (server PortableDoc blocks) or plain
 * text. Nothing in between — there is no partial-markdown state. */
export type BodyRender =
  | { kind: 'blocks'; blocks: Block[] }
  | { kind: 'text'; text: string }

/** The rows whose body is a two-phase DECISION — and the progressive rows are
 * deliberately NOT among them.
 *
 * A committed segment is already a document: the server converted it, there is
 * nothing left to decide, and giving it an arm here would add a second
 * unreachable branch of exactly the kind mob-rt-s3 had to go and pin from the
 * outside (bodyRender's tail arm is dead for the UI — TranscriptRow returns
 * first). A placeholder is not a body at all. So the type says so, and no dead
 * arm exists to be mutated without consequence. */
export type BodyRow = Exclude<Row, { kind: 'segment' } | { kind: 'skeleton' }>

/** How a settled row is drawn, mirroring the TUI taxonomy verbatim
 * (internal/chat/render.go renderMessage's switch):
 *
 *   assistant   — the reply body, rendered as a document.
 *   user        — the bubble; NEVER blocks (the #6126 law).
 *   card        — approval/question/plan: the block is the card's BODY, but
 *                 answerability stays on the envelope (D35), so these route to
 *                 CardRow which wraps the body with the Allow/Deny footer.
 *   block       — tool/todo/thinking: the server carries exactly ONE typed
 *                 chat-* block, so the transcript draws a real diff/checklist/
 *                 thought row instead of one dim line.
 *   structural  — the forward-compatible default arm: `system` (nothing to
 *                 promote) and any unknown future role render the SAME honest
 *                 dim provenance line, so the two were one kind wearing two
 *                 names — the separate `unknown` arm had no observable
 *                 consequence anywhere and is folded in (never a crash,
 *                 never a blank).
 *
 * Pure and exported so the taxonomy itself is jest-pinnable. */
export type RoleKind = 'assistant' | 'user' | 'card' | 'block' | 'structural'

const BLOCK_ROLES = new Set(['tool', 'todo', 'thinking'])

export function roleKind(role: string): RoleKind {
  if (role === 'assistant') return 'assistant'
  if (role === 'user') return 'user'
  if (isCardRole(role)) return 'card'
  if (BLOCK_ROLES.has(role)) return 'block'
  return 'structural'
}

/** The roles whose rows carry a renderable chat-* block — the SIX the server
 * projects a typed block onto. `user` is deliberately absent (bubble law) and
 * so is `system` (nothing visual to promote). */
export function rendersBlocks(role: string): boolean {
  const kind = roleKind(role)
  return kind === 'assistant' || kind === 'card' || kind === 'block'
}

/** THE LIST'S SIZE BUCKET for a row — LegendList's `getItemType` (charter D65).
 *
 * Without it every row shares ONE bucket (legend-list keys its running average
 * on `itemType`, which is the empty string when no `getItemType` is given), so
 * the per-type averages are a single blended number and ESTIMATED_ROW_HEIGHT
 * — 180px, sized for a short assistant paragraph — is the last-resort estimate
 * for a one-line log handle and a forty-line code turn alike. Bucketed, each
 * kind learns its OWN average and the list positions off that.
 *
 * The buckets are the kinds a row is actually DRAWN by, which is why message
 * rows split on `roleKind`: a user bubble, an assistant document, an approval
 * card and a tool row leave TranscriptRow through four different arms with four
 * unrelated height distributions, and averaging them together is exactly the
 * dishonesty this fixes. `getFixedItemSize` is deliberately NOT used — these
 * heights are unknown, not fixed.
 *
 * A module-level function, not an inline arrow: the list prop stays identity-
 * stable across renders, and the mapping is reachable by jest. */
export function transcriptItemType(row: Row): string {
  if (row.kind === 'message') return `message:${roleKind(row.message.role)}`
  // A committed segment buckets on the block that OPENS it, because that is what
  // decides its height distribution: a one-line heading segment and a forty-line
  // code segment share nothing but the word "segment", and averaging them
  // together is the same dishonesty the message rows split to avoid. An empty
  // blocks array cannot reach here (the reducer refuses a blockless frame), but
  // the fallback names itself rather than emitting a bare `segment:`.
  //
  // AND on whether the row opens its turn (mob-lm-s5f-segment-size-bucket): the
  // measured height of a turn-OPENING segment includes rowLead's 18px
  // turn-boundary wrapper while a continuing segment's does not, so one bucket
  // blended both and every estimate in it was wrong by a predictable 18·p. The
  // ordering fact rides on the row (stableSegmentRows stamps `opensTurn`)
  // because this function receives (item, index) and can never see the
  // predecessor. CHOSEN ANSWER for that row: split the bucket — the fix is two
  // tokens on an existing seam, cheaper than proving 18px unobservable.
  if (row.kind === 'segment') {
    return `segment:${row.opensTurn ? 'lead:' : ''}${row.blocks[0]?.type ?? 'unknown'}`
  }
  return row.kind
}

/** Does this blocks array have anything the renderer can actually DRAW?
 *
 * `renderBlockNative` never throws and never renders nothing: an unregistered
 * type degrades to the labeled dashed box. That is right per BLOCK — a mixed
 * turn should show the paragraphs it has and be honest about the one block this
 * client is too old to draw — and wrong per TURN: a turn whose blocks are ALL
 * unknown paints a stack of dashed boxes and NO answer, while the full text of
 * that answer sits unused in `source_markdown` on the very same row. So the
 * decision is per turn and it is made HERE, screen-side: the block layer keeps
 * its per-block honesty untouched (zero diffs), and the transcript asks it one
 * question first — is there a single block worth entering the document path
 * for?
 *
 * BLOCK_RENDERERS is the registry `renderBlockNative` itself dispatches on, so
 * this can never disagree with what would be drawn — including the chat-* rows,
 * which are spread into that same registry.
 *
 * MINUS THE DEGRADE-ONLY TYPES (charter D47). Registration is not the same claim
 * as renderability: `video` and `asciicast` are registered to DEGRADE CARDS —
 * labeled boxes that state their ceiling — and a turn made of nothing but those
 * is a turn this client cannot really draw. Counting them here would flip such a
 * turn off the text path it takes today and paint summary cards INSTEAD of the
 * full `source_markdown`, which is strictly less than the answer. The subtraction
 * lives at TURN level only: `renderBlockNative` still draws the card, so a MIXED
 * turn gets its prose AND its card. See DEGRADE_ONLY in registry.tsx. */
export function anyRenderableBlocks(blocks: readonly Block[]): boolean {
  return blocks.some((b) => BLOCK_RENDERERS[b.type] !== undefined && !DEGRADE_ONLY.has(b.type))
}

/** THE two-phase decision, pure so jest can pin it without a native host.
 *
 * Phase 1 — the UNSETTLED REMAINDER is always plain text: the `tail` row carries
 * a growing STRING and no blocks field at all, so a half-written `**bold` is
 * structurally incapable of flashing as markup. That law is unchanged in
 * substance and narrowed in scope by charter D59: what the row carries is now the
 * part of the turn the SERVER has not yet declared settled, and the settled part
 * is drawn — converted once, server-side — as its own `segment` rows. A client
 * markdown parser would be the fork this whole design exists to prevent, and
 * there still is not one. Phase 2 — at turn settle the tail is replaced by the
 * persisted `message` row, which carries the server's already-converted blocks.
 * Local echoes are the user's own words: plain, always.
 *
 * Every block-BEARING role takes the blocks path; a row that arrived without
 * usable blocks (a mid-persist frame, or a thinner server) — or with blocks this
 * client cannot draw a single one of (anyRenderableBlocks) — degrades honestly
 * to its source text, the same tolerance render.go's renderStructuralDoc
 * shows. */
export function bodyRender(row: BodyRow): BodyRender {
  if (row.kind === 'tail') return { kind: 'text', text: row.text }
  if (row.kind === 'local') return { kind: 'text', text: row.content }
  // A log header stands for rows it does not contain, so its body is the
  // count and nothing more (workLogSummary owns that wording).
  if (row.kind === 'log') return { kind: 'text', text: workLogSummary(row.group) }
  const m = row.message
  if (rendersBlocks(m.role)) {
    const blocks = messageBlocks(m)
    if (blocks !== undefined && anyRenderableBlocks(blocks)) return { kind: 'blocks', blocks }
  }
  return { kind: 'text', text: (m.source_markdown ?? '').trim() }
}

/** The ctx every settled assistant turn renders under: the SAME block
 * renderers the paper reader uses, speaking the chat register (charter D22).
 *
 * This is a standalone function rather than an inline object literal so the
 * register binding is REACHABLE by jest. Inlined in the useMemo it was
 * unpinnable: deleting `register: 'chat'` silently demoted every assistant
 * turn to the paper serif and the whole suite stayed green. */
export function chatBlockCtx(theme: Theme, serverBase?: string): BlockCtx {
  return { theme, serverBase, register: 'chat' }
}

export function ChatSessionScreen({
  connection,
  sessionId,
  sessionTitle,
  onArchive,
  onBack,
}: {
  connection: InstanceConnection
  sessionId: string
  /** the list row's title — painted until the full GET lands its own. */
  sessionTitle?: string
  /** Dismiss this session (charter D28). The OWNER does the navigating: it
   * pops out of the session it just archived (nextOpenAfterArchive), which is
   * why this screen only reports the intent and never routes. */
  onArchive?: (id: string) => void
  onBack: () => void
}) {
  const theme = useTheme()
  const {
    state,
    choices,
    loading,
    loadError,
    transportError,
    streamStatus,
    streamFailure,
    send,
    interrupt,
    answer,
    setChoice,
    retry,
  } = useChatSession(connection, sessionId)
  const [draft, setDraft] = useState('')
  const [pickersOpen, setPickersOpen] = useState(false)
  // The picker vocabulary, discovered once per connection (charter D27). A
  // server that does not advertise the block, or refuses the read, lands
  // `undefined` — which the sheet renders as an honest "nothing advertised",
  // never as a hardcoded claude-shaped guess.
  const [capabilities, setCapabilities] = useState<ChatCapabilities | undefined>(undefined)
  useEffect(() => {
    let alive = true
    fetchChatCapabilities(connection)
      .then((caps) => {
        if (alive) setCapabilities(caps)
      })
      .catch(() => {
        if (alive) setCapabilities(undefined)
      })
    return () => {
      alive = false
    }
  }, [connection])
  const openPickers = useCallback(() => {
    haptic('disclosureToggle')
    setPickersOpen(true)
  }, [])
  const closePickers = useCallback(() => setPickersOpen(false), [])
  const onPick = useCallback(
    (kind: PickerKind, value: string) => setChoice(kind, value),
    [setChoice],
  )
  // Archiving is a DISMISSAL, so the sheet closes and the owner pops us out —
  // staying inside a session you just dismissed is the incoherent state D28
  // exists to prevent.
  const onArchiveSession = useMemo(
    () =>
      onArchive === undefined
        ? undefined
        : () => {
            setPickersOpen(false)
            onArchive(sessionId)
          },
    [onArchive, sessionId],
  )
  const listRef = useRef<LegendListRef>(null)
  const [follow, setFollow] = useState<FollowState>(initialFollowState)
  const [fold, setFold] = useState(initialWorkLogFold)

  const blockCtx = useMemo<BlockCtx>(
    () => chatBlockCtx(theme, connection.projectUrl),
    [theme, connection.projectUrl],
  )

  // Three memos, not one — see assembleRows: the split is what keeps a settled
  // row's identity (and therefore memo(TranscriptRow)) alive across a tail tick.
  const settledRows = useMemo(() => messageRows(state.messages), [state.messages])
  const echoRows = useMemo(() => localRows(state.local), [state.local])

  // The live document (charter D59). The table is a memo TABLE, exactly like
  // headerTable below: written during render, never state, never a ref, and
  // idempotent — a second pass over the same segments hands back the same rows.
  // It is what keeps a committed paragraph's row identity alive across the NEXT
  // commit, not merely across a delta.
  const segTable = useMemo(() => new Map<string, Row>(), [])
  const segmentRows = useMemo(
    () => stableSegmentRows(segTable, state.segments),
    [segTable, state.segments],
  )
  const segmentsByTurn = useMemo(() => groupSegmentRows(segmentRows), [segmentRows])
  const remainder = tailRemainder(state)
  // Absent unless the server is actually emitting segments: with none, this is
  // `undefined` and assembleRows takes the path it has always taken.
  const live = useMemo<LiveDoc | undefined>(() => {
    if (segmentRows.length === 0 && state.skeleton === null) return undefined
    return {
      byTurn: segmentsByTurn,
      suppressed: state.suppressed,
      liveTurn: state.stableTurn,
      remainder,
      skeleton: state.skeleton,
    }
  }, [segmentRows, segmentsByTurn, state.suppressed, state.stableTurn, remainder, state.skeleton])
  const rows = useMemo(
    () => assembleRows(settledRows, echoRows, state.tail, live),
    [settledRows, echoRows, state.tail, live],
  )

  // The work log, folded on the D77 clock. `gen` is the reducer's own turn
  // generation, read and never written (workLog.ts is a read-only consumer).
  const groups = useMemo(() => workLogGroups(workLogRows(rows)), [rows])
  // Stamp the clock onto any newly-appeared group and PERSIST it — during
  // render, which is React's documented "adjust state while rendering" (the
  // update is conditional and converges in one pass). Deriving it instead was
  // a live bug: re-running observeGroups against the un-persisted fold would
  // re-stamp every group with the CURRENT gen on every render, so a group's
  // birth gen chased the clock and nothing ever folded.
  // The clock can go BACKWARDS, and only one path does it: retry() (the
  // "signed out — sign in again" wall) rebuilds the store inside
  // useChatSession, so state restarts at gen 0 — but this screen does NOT
  // remount, so `fold` survives with births stamped against the OLD clock.
  // Every born >= 0, so every collapsed work log would spring open the instant
  // the user re-authenticated. A regression means a different session's
  // history: drop the stamps rather than reinterpret them under a clock they
  // were never taken on.
  const [seenGen, setSeenGen] = useState(state.gen)
  if (state.gen < seenGen) {
    setSeenGen(state.gen)
    setFold(initialWorkLogFold)
  } else if (state.gen > seenGen) {
    setSeenGen(state.gen)
  }

  // The fold's clock is PINNED while the reader is away from the end (see
  // freezeFold): an auto-fold removes height, and a reader who scrolled up must
  // not have the line they are reading slide away because a turn finished
  // somewhere below them. Both writes ride the one setFold — a second
  // render-phase setState on the same value would be a wasted pass.
  const observed = freezeFold(observeGroups(fold, groups, state.gen), state.gen, follow.following)
  if (observed !== fold) setFold(observed)
  const isOpen = useCallback(
    (key: string) => workLogExpanded(observed, key, state.gen),
    [observed, state.gen],
  )
  // The header rows survive a token frame by IDENTITY (workLogHeaderCache) —
  // without this every apparatus group's header re-rendered on every delta,
  // which is the one cost PROBE D still measured after the row memos landed.
  // A useMemo'd Map, not state and not a ref: it is a memo TABLE, so writing it
  // must neither schedule a render nor count as reading a ref during one, and
  // the lookup is idempotent — a second render pass over the same groups hands
  // back the same row objects.
  const headerTable = useMemo(() => new Map<string, CachedHeader<Row>>(), [])
  const listRows = useMemo(() => {
    const header = workLogHeaderCache<Row>(headerTable, groups, (group, open) => ({
      key: `log-${group.key}`,
      kind: 'log',
      group,
      open,
    }))
    return foldWorkLog<Row>(rows, groups, (row) => row.key, isOpen, header)
  }, [headerTable, rows, groups, isOpen])

  // Deliberately NOT dependent on `groups`: that array is re-derived on every
  // token frame, so a handler keyed on it would change identity per frame,
  // re-mint every row's props through rowCtx, and make memo(TranscriptRow)
  // inert all over again. It does not need groups — the birth gen is already
  // persisted in `fold` by the render-phase stamp above.
  const toggleLog = useCallback(
    (key: string) => {
      haptic('disclosureToggle')
      setFold((f) => toggleWorkLog(f, key, state.gen))
    },
    [state.gen],
  )

  // Follow mode. The LIST does the pinning (maintainScrollAtEnd); this only
  // tracks whether the user is following, so the pill knows whether it has
  // anything to offer. Disengagement is structural — the user scrolled — and
  // never a timer, which is what the two removed scrollToEnd yanks were.
  //
  // `mark` is how much content is below, right now: the pill compares it
  // against the mark follow was lost at, so "new content arrived" needs no
  // observer, no effect and no counter.
  const mark = contentMark(rows.length, state.tail.length)

  const onScroll = useCallback(
    (e: NativeSyntheticEvent<NativeScrollEvent>) => {
      const { contentOffset, contentSize, layoutMeasurement } = e.nativeEvent
      setFollow((f) =>
        reduceFollow(f, {
          type: 'scrolled',
          distanceFromEnd: distanceFromEnd({
            contentHeight: contentSize.height,
            offsetY: contentOffset.y,
            viewportHeight: layoutMeasurement.height,
          }),
          viewportHeight: layoutMeasurement.height,
          mark,
        }),
      )
    },
    [mark],
  )

  /** The observed-intent latch (followScroll's `dragged`). onScrollBeginDrag is
   * the ONE scroll-view callback a finger is the only source of: a keyboard
   * dismissal, a rotation, a late row measurement and the list's own
   * maintainScrollAtEnd re-pin all fire onScroll and none of them fire this. So
   * a geometric re-engage is licensed here and nowhere else. */
  const onDragBegin = useCallback(() => {
    setFollow((f) => reduceFollow(f, { type: 'dragged' }))
  }, [])

  /** The ONE re-engage path — the pill and send share it, and nothing else in
   * this file scrolls the transcript. */
  const reFollow = useCallback((cause: 'jumped' | 'sent') => {
    setFollow((f) => reduceFollow(f, { type: cause }))
    listRef.current?.scrollToEnd({ animated: true })
  }, [])

  const onJump = useCallback(() => {
    // D43: the pill's tick under its own name. Re-engaging follow is a position
    // choice, not a disclosure — same feedback, honest label.
    haptic('jumpToLatest')
    reFollow('jumped')
  }, [reFollow])

  const onSend = useCallback(() => {
    const content = draft.trim()
    if (content === '') return
    setDraft('')
    send(content)
    reFollow('sent')
  }, [draft, send, reFollow])

  // ONE memoized ctx, not an object literal per row: an inline literal would
  // be a fresh identity on every render, which the comparator reads as
  // "changed" for every row. Every field here survives a tail tick — the
  // reducer keeps answerInFlight, and the two handlers are keyed on things
  // that move per TURN at most.
  const rowCtx = useMemo<RowCtx>(
    () => ({
      theme,
      blockCtx,
      inFlight: state.answerInFlight,
      onAnswer: answer,
      onToggleLog: toggleLog,
    }),
    [theme, blockCtx, state.answerInFlight, answer, toggleLog],
  )

  // `data` and `index` come from the list, not from a closure, so the callback
  // stays identity-stable across a tail tick exactly as it did — and the lead is
  // a fact about the ORDERING, which is the only place it can honestly be read.
  const renderItem = useCallback(
    ({ item, index, data }: { item: Row; index: number; data: readonly Row[] }) =>
      transcriptItem(item, rowCtx, rowLead(data, index)),
    [rowCtx],
  )

  const title = state.title !== '' ? state.title : (sessionTitle ?? sessionId)
  const turnActive = state.phase !== 'idle'
  const connLabel = headerStatus(streamStatus, streamFailure)
  // The composer is DISABLED behind a refused wall (sending into a dead stream
  // would lie) but stays EDITABLE while degraded — the transcript is intact
  // and the retry loop is live.
  const composerBlocked = loading || loadError !== undefined || streamStatus === 'refused'

  let body
  if (loading) {
    body = (
      <View style={styles.center}>
        <ActivityIndicator color={theme.accent} />
        <Text style={[styles.muted, { color: theme.textMuted }]}>Loading session…</Text>
      </View>
    )
  } else if (loadError !== undefined) {
    body = (
      <View style={styles.center}>
        <Text style={[styles.body, { color: theme.danger }]}>
          Could not load this session. {loadError}
        </Text>
        <Pressable accessibilityRole="button" onPress={retry}>
          <Text style={[styles.link, { color: theme.accent }]}>Try again</Text>
        </Pressable>
      </View>
    )
  } else {
    body = (
      <LegendList
        ref={listRef}
        data={listRows}
        keyExtractor={(row: Row) => row.key}
        dataKey={sessionId}
        estimatedItemSize={ESTIMATED_ROW_HEIGHT}
        // Per-kind size buckets — without this every row is averaged together
        // and positioned off ESTIMATED_ROW_HEIGHT (see transcriptItemType).
        getItemType={transcriptItemType}
        // EXPLICIT, and load-bearing (charter D56/D65 — the comment D56 promised
        // at crown). false is legend-list's default, but leaving it implicit
        // leaves the transcript one prop away from silent breakage: recycling
        // drops the row key (`key: recycleItems ? undefined : itemKey`), and a
        // keyless row voids memo(TranscriptRow)'s identity contract — the whole
        // reason a tail tick costs one render instead of the transcript. The
        // rows are heterogeneous documents; there is no pool to reuse.
        recycleItems={false}
        initialScrollAtEnd
        maintainScrollAtEnd={TRANSCRIPT_FOLLOW}
        maintainScrollAtEndThreshold={FOLLOW_THRESHOLD}
        onScroll={onScroll}
        onScrollBeginDrag={onDragBegin}
        contentContainerStyle={styles.listContent}
        ListEmptyComponent={
          <View style={styles.center}>
            <Text style={[styles.muted, { color: theme.textMuted }]}>
              No messages yet — send one to start the session.
            </Text>
          </View>
        }
        renderItem={renderItem}
      />
    )
  }

  const notice = transportError ?? (state.notice !== '' ? state.notice : undefined)

  return (
    <KeyboardAvoidingView
      style={[styles.root, { backgroundColor: theme.bg }]}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <View style={[styles.header, { backgroundColor: theme.bg }]}>
        <Pressable accessibilityRole="button" onPress={onBack} hitSlop={12}>
          <Text style={[styles.back, { color: theme.text }]}>‹</Text>
        </Pressable>
        <Text numberOfLines={1} style={[styles.headerTitle, { color: theme.text }]}>
          {title}
        </Text>
        <View style={styles.headerMeta}>
          {/* The mode badge IS the picker affordance — the one thing already
              in the header that names a session choice, so opening the sheet
              from it adds an interaction, not a control. */}
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Session options"
            hitSlop={8}
            onPress={openPickers}
          >
            <Text style={[styles.metaBadge, { color: theme.textMuted }]}>
              {state.mode !== '' ? state.mode : 'options'}
            </Text>
          </Pressable>
          {connLabel !== undefined &&
            (connLabel.action !== undefined ? (
              <Pressable
                accessibilityRole="button"
                hitSlop={8}
                onPress={connLabel.action === 'back' ? onBack : retry}
              >
                <Text style={[styles.metaBadge, { color: theme.danger }]}>{connLabel.text}</Text>
              </Pressable>
            ) : (
              <Text
                style={[
                  styles.metaBadge,
                  { color: connLabel.tone === 'danger' ? theme.danger : theme.textMuted },
                ]}
              >
                {connLabel.text}
              </Text>
            ))}
        </View>
      </View>

      <View style={styles.transcript}>
        {body}
        {/* The pill floats OVER the transcript and nothing else does — the
            header stays an opaque plain View on the background (D29's
            tripwire: a translucent or absolutely-positioned header re-opens
            t3code's 922-line automatic-inset patch, which this app is
            unpatched precisely because it does not need). */}
        {showJumpPill(follow, mark) && (
          <View style={styles.jumpLayer} pointerEvents="box-none">
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Jump to the latest message"
              onPress={onJump}
              style={[styles.jumpPill, { backgroundColor: theme.surface, borderColor: theme.border }]}
            >
              <Text style={[styles.jumpGlyph, { color: theme.text }]}>↓</Text>
            </Pressable>
          </View>
        )}
      </View>

      {notice !== undefined && (
        <Text style={[styles.notice, { color: theme.textMuted }]}>{notice}</Text>
      )}

      <View style={[styles.composer, { backgroundColor: theme.bg }]}>
        <TextInput
          style={[
            styles.input,
            { color: theme.text, backgroundColor: theme.surface, borderColor: theme.border },
          ]}
          placeholder={state.exited ? 'Send to relaunch…' : 'Message…'}
          placeholderTextColor={theme.textMuted}
          value={draft}
          onChangeText={setDraft}
          multiline
          editable={!composerBlocked}
        />
        {turnActive ? (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Stop the running turn"
            onPress={interrupt}
            style={[styles.roundBtn, { backgroundColor: theme.surface, borderColor: theme.border, borderWidth: StyleSheet.hairlineWidth }]}
          >
            <Text style={[styles.stopGlyph, { color: theme.danger }]}>■</Text>
          </Pressable>
        ) : null}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Send message"
          onPress={onSend}
          disabled={draft.trim() === '' || composerBlocked}
          style={[
            styles.roundBtn,
            { backgroundColor: draft.trim() === '' ? theme.border : theme.accent },
          ]}
        >
          <Text style={[styles.sendGlyph, { color: theme.accentText }]}>↑</Text>
        </Pressable>
      </View>

      <PickerSheet visible={pickersOpen} onClose={closePickers} theme={theme} capabilities={capabilities} choices={choices} observedModel={state.model} onPick={onPick} onArchive={onArchiveSession} />
    </KeyboardAvoidingView>
  )
}

/** Everything a row needs that is not the row — hoisted into one named shape
 * so the screen's renderItem has a single memo dependency to keep stable. */
export interface RowCtx {
  theme: Theme
  blockCtx: BlockCtx
  inFlight: Record<string, string>
  onAnswer: (requestId: string, decision: 'allow' | 'deny') => void
  /** The work-log disclosure. Optional because only the `log` row uses it and
   * every other row must stay callable from jest with the props it always
   * took — the hook-free contract cuts both ways. */
  onToggleLog?: (groupKey: string) => void
}

export interface TranscriptRowProps extends RowCtx {
  row: Row
}

/** One transcript row. Hook-free by design (like the block renderers), so the
 * jest suite can call it directly and walk the element tree it returns —
 * that is what pins the blocks branch actually being wired up. */
export function TranscriptRow({
  row,
  theme,
  blockCtx,
  inFlight,
  onAnswer,
  onToggleLog,
}: TranscriptRowProps) {
  if (row.kind === 'log') {
    // The turn's labour, behind one quiet handle. Deliberately in the mono
    // apparatus register the chat-* rows speak (13/19), not the prose one —
    // this is chrome about the answer, never the answer.
    return (
      <Pressable
        accessibilityRole="button"
        accessibilityState={{ expanded: row.open }}
        accessibilityLabel={`${row.open ? 'Hide' : 'Show'} the work log — ${workLogSummary(row.group)}`}
        hitSlop={10}
        onPress={() => onToggleLog?.(row.group.key)}
        style={styles.logHeader}
      >
        <Text style={[styles.logHeaderText, { color: theme.textMuted }]}>
          {`${row.open ? '▾' : '▸'} ${workLogSummary(row.group)}`}
        </Text>
      </Pressable>
    )
  }
  if (row.kind === 'local') {
    // A rejected send keeps the user's words — losing them would be worse than
    // relabelling them — but it stops wearing the delivered bubble: the danger
    // family (the app's vocabulary for "this did not happen", where `warn` is
    // reserved for "unconfirmed"), and a line that says so in words rather than
    // in colour alone. `queued` never shows alongside it: a failed send is not
    // waiting its turn.
    if (row.failed === true) {
      return (
        <View
          accessibilityLabel={`Not sent: ${row.content}`}
          style={[
            styles.userBubble,
            styles.failedBubble,
            { backgroundColor: theme.dangerSoft, borderColor: theme.danger },
          ]}
        >
          <Text style={[styles.userText, { color: theme.text }]}>{row.content}</Text>
          <Text style={[styles.queuedBadge, { color: theme.danger }]}>⚠ not sent</Text>
        </View>
      )
    }
    return (
      <View style={[styles.userBubble, { backgroundColor: theme.bubble }]}>
        <Text style={[styles.userText, { color: theme.text }]}>{row.content}</Text>
        {row.queued && (
          <Text style={[styles.queuedBadge, { color: theme.textMuted }]}>⧗ queued</Text>
        )}
      </View>
    )
  }
  if (row.kind === 'tail') {
    // The streaming tail is an assistant turn in progress: the same unbubbled
    // document text, with a quiet inline cursor as the only liveness mark.
    // Phase 1 of the two-phase floor — plain, never markup (see bodyRender).
    return (
      <Text style={[styles.assistantText, { color: theme.text }]}>
        {row.text}
        <Text style={{ color: theme.textMuted }}> ▍</Text>
      </Text>
    )
  }
  if (row.kind === 'segment') {
    // A COMMITTED segment of the turn still being written — drawn through the
    // very same container and the very same renderers a settled assistant turn
    // uses below, and that identity is the whole point: at settle this row does
    // not change, because there is nothing it could change into. Not a
    // mid-stream approximation of the document; the document, arriving in
    // pieces.
    return (
      <View style={styles.assistantDoc}>
        {row.blocks.map((b, i) => renderBlockNative(b, blockCtx, i))}
      </View>
    )
  }
  if (row.kind === 'skeleton') {
    // The block the answer is part-way through. Its prose streams live ABOVE the
    // box (StreamSkeleton draws it) so a paragraph sitting under a forming table
    // keeps moving instead of vanishing behind it — the web hides 100% of those
    // bytes and that defect is deliberately not ported (charter D67).
    return <StreamSkeleton kind={row.label} prose={row.prose} />
  }

  const m = row.message
  // Cards keep their interactive shell whether or not a block arrived — the
  // answer path is envelope-driven (D35), so CardRow owns the frame and the
  // Allow/Deny footer and only its BODY becomes the typed chat-* block.
  if (isCard(m))
    return (
      <CardRow
        m={m}
        theme={theme}
        blockCtx={blockCtx}
        inFlight={inFlight}
        onAnswer={onAnswer}
      />
    )

  const body = bodyRender(row)
  if (body.kind === 'blocks') {
    // Phase 2 — a settled assistant turn, or a tool/todo/thinking row carrying
    // its typed chat-* block. Either way the answer is a document: full-width,
    // directly on the background — no bubble, no border, no chrome. The server
    // already converted this row to PortableDoc, so render THOSE blocks through
    // the very renderer the paper reader uses, speaking the chat register.
    return (
      <View style={styles.assistantDoc}>
        {body.blocks.map((b, i) => renderBlockNative(b, blockCtx, i))}
      </View>
    )
  }
  if (m.role === 'user') {
    // The one structural law: the user speaks in a soft rounded bubble — and
    // never renders blocks (the #6126 bubble law: 16/23, plain, verbatim).
    return (
      <View style={[styles.userBubble, { backgroundColor: theme.bubble }]}>
        <Text style={[styles.userText, { color: theme.text }]}>{body.text}</Text>
      </View>
    )
  }
  if (m.role === 'assistant') {
    // An assistant turn that arrived without blocks (a row persisted before
    // the conversion, or a server that does not send them) keeps the plain
    // text it always had — never an empty turn.
    return <Text style={[styles.assistantText, { color: theme.text }]}>{body.text}</Text>
  }
  // Blockless structural rows (`system`) and any forward-compatible unknown
  // role: one honest muted provenance line — never hidden, never a crash.
  if (body.text === '') return null
  return (
    <Text numberOfLines={3} style={[styles.systemLine, { color: theme.textMuted }]}>
      {m.role}: {body.text}
    </Text>
  )
}

/** THE MEMO COMPARATOR, written out rather than left to memo's default shallow
 * compare — because the whole point is that it is checkable. Every prop is
 * identity-compared, which is only sound because each one is built to survive
 * a tail tick: `row` comes from the split row memos (assembleRows), `blockCtx`
 * and the two handlers are useMemo/useCallback-stable, and `inFlight` is the
 * reducer's answerInFlight, which a delta frame never re-mints.
 *
 * Returning TRUE means React SKIPS the re-render. */
export function transcriptRowPropsEqual(a: TranscriptRowProps, b: TranscriptRowProps): boolean {
  return (
    a.row === b.row &&
    a.theme === b.theme &&
    a.blockCtx === b.blockCtx &&
    a.inFlight === b.inFlight &&
    a.onAnswer === b.onAnswer &&
    a.onToggleLog === b.onToggleLog
  )
}

/** What the LIST renders. TranscriptRow stays exported as the raw function so
 * jest keeps calling it directly; the list goes through this memo, and
 * transcriptItem is the seam that proves it does. */
export const MemoTranscriptRow = memo(TranscriptRow, transcriptRowPropsEqual)

/** One list item. The screen's renderItem is a useCallback around THIS, so the
 * "settled rows do not re-render on tail ticks" law has a reachable name: an
 * edit that drops the memo (rendering TranscriptRow directly) changes what
 * this returns, and the pin reds.
 *
 * The lead lives on a WRAPPER rather than on the row's own arms, for two
 * reasons. A row leaves TranscriptRow through ten different arms — a Pressable,
 * two bubbles, three bare Texts, two document Views, a StreamSkeleton and a
 * CardRow — and two of those are components that take no style at all, so
 * "apply the margin to whatever it returned" is the only rule that holds for
 * all ten. And it must sit INSIDE the item container legend-list measures, so
 * the height the list learns for a row includes its lead and the scroll anchor
 * cannot drift; a wrapper is inside, the container's own style is not ours. */
export function transcriptItem(row: Row, ctx: RowCtx, lead = 0): ReactElement {
  return (
    <View style={lead === 0 ? undefined : styles.rowLead}>
      <MemoTranscriptRow row={row} {...ctx} />
    </View>
  )
}

/** An approval / question / plan row. Hook-free like TranscriptRow so jest can
 * call it directly — that is what pins the card BODY actually rendering the
 * typed chat-* block rather than the raw markdown. */
export function CardRow({
  m,
  theme,
  blockCtx,
  inFlight,
  onAnswer,
}: {
  m: ChatMessage
  theme: Theme
  blockCtx: BlockCtx
  inFlight: Record<string, string>
  onAnswer: (requestId: string, decision: 'allow' | 'deny') => void
}) {
  const rid = requestId(m)
  const status = approvalStatus(m)
  const pendingDecision = inFlight[rid]
  const canAnswer = answerable(m) && pendingDecision === undefined
  // The card BODY is the server's typed chat-approval/question/plan block when
  // one arrived (the TUI's cardBodyLines twin); a blockless row — or one whose
  // blocks this client cannot draw a single one of — keeps the plain markdown it
  // always showed, because a card asking for a decision must never present the
  // decision as a dashed box. The frame and footer below are the envelope's,
  // untouched either way — the block never carries the answer (D35).
  const raw = messageBlocks(m)
  const blocks = raw !== undefined && anyRenderableBlocks(raw) ? raw : undefined
  return (
    <View style={[styles.card, { borderColor: theme.border, backgroundColor: theme.surface }]}>
      <Text style={[styles.cardTitle, { color: theme.textMuted }]}>
        {CARD_TITLES[m.role] ?? m.role}
      </Text>
      {blocks !== undefined ? (
        <View>{blocks.map((b, i) => renderBlockNative(b, blockCtx, i))}</View>
      ) : (
        <Text style={[styles.cardBody, { color: theme.text }]}>
          {(m.source_markdown ?? '').trim()}
        </Text>
      )}
      {pendingDecision !== undefined ? (
        <Text style={[styles.cardStatus, { color: theme.textMuted }]}>
          answering: {pendingDecision}…
        </Text>
      ) : status !== '' && status !== 'pending' ? (
        <Text
          style={[styles.cardStatus, { color: status === 'allowed' ? theme.success : theme.danger }]}
        >
          {status}
        </Text>
      ) : canAnswer ? (
        <View style={styles.cardActions}>
          <Pressable
            accessibilityRole="button"
            onPress={() => onAnswer(rid, 'allow')}
            style={[styles.pillBtn, { backgroundColor: theme.accent }]}
          >
            <Text style={[styles.pillBtnText, { color: theme.accentText }]}>Allow</Text>
          </Pressable>
          <Pressable
            accessibilityRole="button"
            onPress={() => onAnswer(rid, 'deny')}
            style={[
              styles.pillBtn,
              { borderColor: theme.border, borderWidth: StyleSheet.hairlineWidth },
            ]}
          >
            <Text style={[styles.pillBtnText, { color: theme.danger }]}>Deny</Text>
          </Pressable>
        </View>
      ) : (
        <Text style={[styles.cardStatus, { color: theme.textMuted }]}>pending</Text>
      )}
    </View>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  // The header sits on the background — no surface slab, no border. The
  // title and whitespace carry it (the ChatGPT/Claude register).
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 18,
    paddingTop: 54,
    paddingBottom: 12,
  },
  back: { ...roles.backGlyph, fontWeight: '400', marginTop: -2 },
  headerTitle: { flex: 1, ...scale.lg, fontWeight: '600' },
  headerMeta: { flexDirection: 'row', gap: 8 },
  metaBadge: { ...scale.xs },
  transcript: { flex: 1 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, padding: 24 },
  // Generous vertical rhythm between turns — whitespace is the hierarchy.
  // NO `gap` — see TRANSCRIPT_ROW_GAP. A gap here is stripped by legend-list and
  // re-emitted onto every item container uniformly, which is precisely what a
  // transcript whose turns arrive in pieces cannot use.
  listContent: { paddingHorizontal: 18, paddingTop: 10, paddingBottom: 20, flexGrow: 1 },
  rowLead: { marginTop: TRANSCRIPT_ROW_GAP },
  // User turns: a soft rounded neutral bubble, right-aligned.
  userBubble: {
    alignSelf: 'flex-end',
    borderRadius: 22,
    paddingHorizontal: 16,
    paddingVertical: 10,
    maxWidth: '80%',
  },
  // The rejected echo: same geometry as the delivered bubble (the words did not
  // move), a different SKIN. The border is what survives a reader who cannot
  // separate the two fills, so it is the assertable half of the difference.
  failedBubble: { borderWidth: 1 },
  // THE BUBBLE LAW (#6126): 16/23 user, 16/26 assistant — the user turn is
  // deliberately tighter than the answer. Both are token-owned now; the
  // rendered pairs are byte-identical to what #6126 settled.
  userText: { ...roles.userBubble },
  // Assistant turns: full-width document text on the background.
  assistantText: { ...roles.chatBody, alignSelf: 'stretch' },
  // The rendered-blocks form of the same turn — the identical full-width,
  // chrome-free frame; the block renderers carry their own vertical rhythm,
  // so this adds no padding of its own.
  assistantDoc: { alignSelf: 'stretch' },
  queuedBadge: { ...scale.micro, marginTop: 4 },
  systemLine: { ...scale.sm, fontStyle: 'italic' },
  // The work-log handle: hugs its text so the tap target is the label, not
  // the full transcript width.
  logHeader: { alignSelf: 'flex-start' },
  logHeaderText: { ...scale.sm, fontFamily: 'monospace' },
  // The re-engage affordance floats over the transcript's bottom edge. The
  // layer is box-none so it never eats a scroll the pill itself is not under.
  jumpLayer: { position: 'absolute', left: 0, right: 0, bottom: 14, alignItems: 'center' },
  jumpPill: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: StyleSheet.hairlineWidth,
  },
  jumpGlyph: { ...roles.jumpGlyph, fontWeight: '600' },
  card: {
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 16,
    padding: 16,
    gap: 10,
    alignSelf: 'stretch',
  },
  cardTitle: { ...scale.micro, fontWeight: '600', textTransform: 'uppercase', letterSpacing: 1 },
  cardBody: { ...scale.md },
  cardStatus: { ...scale.sm, fontWeight: '600' },
  cardActions: { flexDirection: 'row', gap: 10, marginTop: 2 },
  pillBtn: {
    borderRadius: 999,
    paddingHorizontal: 20,
    paddingVertical: 9,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pillBtnText: { ...scale.base, fontWeight: '600' },
  notice: { ...scale.xs, textAlign: 'center', paddingHorizontal: 18, paddingVertical: 4 },
  // The composer floats on the background: a pill input + a round send.
  composer: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: 10,
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 14,
  },
  input: {
    flex: 1,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 22,
    paddingHorizontal: 18,
    paddingTop: 11,
    paddingBottom: 11,
    ...roles.composerInput,
    maxHeight: 120,
  },
  roundBtn: {
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  sendGlyph: { ...roles.sendGlyph, fontWeight: '700' },
  stopGlyph: { ...roles.stopGlyph },
  body: { ...scale.md, textAlign: 'center' },
  muted: { ...scale.sm, textAlign: 'center' },
  link: { ...scale.base, textDecorationLine: 'underline' },
})
