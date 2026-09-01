// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Task board + task list emitters — the JS twins of Components.task_board_html/1
// and Components.tasks_html/1 (charter D14). Written FRESH against the Elixir
// article markup (`bp-board__*` / `bp-bcard*` / `bp-tasks*` / `bp-trow*`); the
// web fork's Tailwind board + LiveView Braille spinner are DISCARDED — only the
// role-bucketing / phase-grouping logic is reused, and the role classes key off
// the status ladder (design/status-manifest.json, see inline.ts STATUS_ROLES).

import {
  type Block,
  escapeHtml,
  str,
  asList,
  isMap,
  capitalize,
  roleOf,
  glyphHtml,
  glyphChar,
  labelForRole,
} from '../inline'
import {
  priorityHtml,
  criteriaHtml,
  workerHtml,
  blockedHtml,
  countRole,
} from './core'

type Emit = (block: Block) => string

/* ── task-board (kanban) — Components.task_board_html/1 ─────────────────────── */

// The board column roles, in white-ladder order (cancel folds to a tally, so it
// is NOT a column). The two thought states — `considering`/`researching` — trail
// at the END (dim; empty columns collapse). Labels are DERIVED (sentence-cased),
// never a second copy. `unknown` is NOT a column: fail-open rows home in `open`
// (placement) while keeping their dim-neutral glyph (styling) — the two decouple.
const BOARD_ROLES = ['open', 'ready', 'progress', 'blocked', 'done', 'considering', 'researching']

function boardLabel(role: string): string {
  return capitalize(labelForRole(role))
}

function boardCol(role: string, label: string, rows: Block[]): string {
  if (rows.length === 0) return ''
  const cards = rows
    .map((r) => {
      const m: Record<string, unknown> = isMap(r) ? r : {}
      // Glyph is per-ROW (its own resolved role), not per-column: a fail-open
      // `unknown` row homed in the `open` column still paints the dim-neutral
      // glyph. For a known row rowRole === the column role, so this is byte-
      // identical to the prior column-role glyph (goldens unaffected).
      const rowRole = roleOf(m.status)
      const title = escapeHtml(str(m.title))
      const meta = priorityHtml(m.priority) + criteriaHtml(m.criteria)
      const metaHtml = meta === '' ? '' : `<div class="bp-bcard__m">${meta}</div>`
      return `<div class="bp-bcard">${glyphHtml(rowRole)}<span class="bp-bcard__t">${title}</span>${metaHtml}</div>`
    })
    .join('')
  return `<div class="bp-board__col bp-board__col--${role}"><div class="bp-board__head"><span class="bp-board__label">${label}</span><span class="bp-board__count">${rows.length}</span></div><div class="bp-board__cards">${cards}</div></div>`
}

const taskBoard: Emit = (b) => {
  const rows = asList<Block>(b.snapshot)
  if (rows.length === 0) return `<div class="bp-tasks bp-tasks--empty">No tasks yet.</div>`
  const byRole: Record<string, Block[]> = {}
  for (const r of rows) {
    const role = roleOf(isMap(r) ? r.status : undefined)
    // Placement decouples from styling: a role WITHOUT a column (the fail-open
    // `unknown` sentinel) homes in `open` so a row never vanishes; its glyph
    // stays the row's own role (see boardCol).
    const col = BOARD_ROLES.includes(role) ? role : 'open'
    ;(byRole[col] ??= []).push(r)
  }
  const cols = BOARD_ROLES.map((role) => boardCol(role, boardLabel(role), byRole[role] ?? []))
    .filter((c) => c !== '')
    .join('')
  return `<div class="bp-board">${cols}</div>`
}

/* ── task list — Components.tasks_html/1 (momentum + phases + rows) ─────────── */

function momentumHtml(rows: Block[]): string {
  const total = rows.length
  if (total === 0) return ''
  const prog = countRole(rows, 'progress')
  const ready = countRole(rows, 'ready')
  const done = countRole(rows, 'done')
  const pct = Math.round((done / total) * 100)
  return (
    `<div class="bp-momentum"><div class="bp-momentum__row">` +
    `<span class="bp-momentum__i">${glyphHtml('progress')}<b>${prog}</b> in flight</span>` +
    `<span class="bp-momentum__i bp-g--ready">${glyphChar('ready')} <b>${ready}</b> ready</span>` +
    `<span class="bp-momentum__i bp-g--done">${glyphChar('done')} <b>${done}</b> done</span>` +
    `<span class="bp-momentum__grow"></span>` +
    `<span class="bp-momentum__pct">${pct}%</span></div>` +
    `<div class="bp-momentum__track"><span class="bp-momentum__fill" style="width:${pct}%"></span></div></div>`
  )
}

function rowHtml(r: Block): string {
  const role = roleOf(r.status)
  const title = escapeHtml(str(r.title))
  const depthRaw = r.depth
  const depth = typeof depthRaw === 'number' && depthRaw > 0 && depthRaw < 6 ? depthRaw : 0
  const pad = 14 + depth * 18
  const arrow = depth > 0 ? `<span class="bp-trow__arr">↳</span>` : ''
  const meta =
    priorityHtml(r.priority) + criteriaHtml(r.criteria) + blockedHtml(r.blocked_by) + workerHtml(r.worker)
  const metaHtml = meta === '' ? '' : `<span class="bp-trow__m">${meta}</span>`
  return (
    `<div class="bp-trow bp-trow--${role}" style="padding-left:${pad}px">` +
    arrow +
    glyphHtml(role) +
    `<span class="bp-trow__t">${title}</span>` +
    metaHtml +
    `</div>`
  )
}

// Group rows by phase label, first-seen order; nil phase renders headerless.
function groupRows(rows: Block[]): Array<[string | null, Block[]]> {
  const order: (string | null)[] = []
  const acc = new Map<string | null, Block[]>()
  for (const r of rows) {
    const raw = str(r.phase).trim()
    const key = raw === '' ? null : raw
    if (!acc.has(key)) {
      order.push(key)
      acc.set(key, [])
    }
    acc.get(key)!.push(r)
  }
  return order.map((k) => [k, acc.get(k)!])
}

function phaseHtml(name: string | null, rows: Block[]): string {
  const body = rows.map(rowHtml).join('')
  if (name === null) return body
  const done = countRole(rows, 'done')
  const total = rows.length
  const hdr =
    `<div class="bp-phase"><span class="bp-phase__nm">${escapeHtml(name)}</span>` +
    `<span class="bp-phase__rule"></span>` +
    `<span class="bp-phase__n">${done}/${total}</span></div>`
  return hdr + body
}

const tasks: Emit = (b) => {
  const rows = asList<Block>(b.snapshot)
  if (rows.length === 0) return `<div class="bp-tasks bp-tasks--empty">No tasks yet.</div>`
  const title = str(b.title).trim()
  const titleHtml = title === '' ? '' : `<div class="bp-tasks__title">${escapeHtml(title)}</div>`
  const body = groupRows(rows)
    .map(([phase, rs]) => phaseHtml(phase, rs))
    .join('')
  return `<div class="bp-tasks">${titleHtml}${momentumHtml(rows)}<div class="bp-tasks__list">${body}</div></div>`
}

export const taskboardEmitters: Record<string, Emit> = {
  'task-board': taskBoard,
  tasks,
  'task-list': tasks,
}
