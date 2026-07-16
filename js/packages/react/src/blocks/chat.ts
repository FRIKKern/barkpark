// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Chat block emitters — the JS twins of components.ex chat_tool_diff_html/1,
// chat_todo_html/1, chat_thinking_html/1 (charter D25). These are STYLE-INVARIANT
// `_raw` rows (mono, evergreen `var(--…)` tokens) rendered BYTE-EXACT to the
// Elixir emitters, including the @chat_diff_budget=20 details/summary fold. The
// derivations are ported verbatim: the LCS line diff (Papers.TextDiff.diff_lines),
// the shape classify (ChatToolRenderer.classify), and the todo glyph — no engine
// is reinvented, so the two surfaces fold at the same row.

import { type Block, escapeHtml, str, asList, isMap } from '../inline'

type Emit = (block: Block) => string

/* ── the LCS line diff (Papers.TextDiff.diff_lines) ────────────────────────── */

const MAX_DIFF_LINES = 2000
const MAX_DIFF_CELLS = 4_000_000

interface DiffLine {
  op: string
  text: string
}

// split on "\n", drop a single trailing empty line; nil/"" → [].
function splitLines(s: unknown): string[] {
  if (typeof s !== 'string' || s === '') return []
  const arr = s.split('\n')
  if (arr.length > 0 && arr[arr.length - 1] === '') arr.pop()
  return arr
}

function diffChunks(a: string[], b: string[]): DiffLine[] {
  const m = a.length
  const n = b.length
  if (m === 0 && n === 0) return []
  if (m > MAX_DIFF_LINES || n > MAX_DIFF_LINES || m * n > MAX_DIFF_CELLS) {
    // Oversized: coarse whole-block diff (all removed, then all added).
    return [...a.map((t) => ({ op: '-', text: t })), ...b.map((t) => ({ op: '+', text: t }))]
  }
  // DP-LCS grid, (m+1)×(n+1), zero border. `noUncheckedIndexedAccess` is on, so
  // row/cell accesses use `!` where the index is provably in-bounds.
  const dp: number[][] = Array.from({ length: m + 1 }, () => new Array<number>(n + 1).fill(0))
  for (let i = 1; i <= m; i++) {
    const prev = dp[i - 1]!
    const cur = dp[i]!
    for (let j = 1; j <= n; j++) {
      cur[j] = a[i - 1] === b[j - 1] ? prev[j - 1]! + 1 : Math.max(prev[j]!, cur[j - 1]!)
    }
  }
  // Backtrack from (m,n) to (0,0), prepending so the result is forward-ordered.
  const out: DiffLine[] = []
  let i = m
  let j = n
  while (i > 0 && j > 0) {
    if (a[i - 1] === b[j - 1]) {
      out.unshift({ op: '=', text: a[i - 1]! })
      i--
      j--
    } else if (dp[i - 1]![j]! >= dp[i]![j - 1]!) {
      out.unshift({ op: '-', text: a[i - 1]! })
      i--
    } else {
      out.unshift({ op: '+', text: b[j - 1]! })
      j--
    }
  }
  while (i > 0) {
    out.unshift({ op: '-', text: a[i - 1]! })
    i--
  }
  while (j > 0) {
    out.unshift({ op: '+', text: b[j - 1]! })
    j--
  }
  return out
}

function diffLines(oldText: unknown, newText: unknown): DiffLine[] {
  return diffChunks(splitLines(oldText), splitLines(newText))
}

/* ── shape classify (ChatToolRenderer.classify) ────────────────────────────── */

function classify(input: unknown): 'edit' | 'write' | 'multi_edit' | 'generic' {
  if (!isMap(input)) return 'generic'
  if (typeof input.file_path === 'string' && Array.isArray(input.edits) && input.edits.length > 0)
    return 'multi_edit'
  if (typeof input.file_path === 'string' && typeof input.old_string === 'string' && typeof input.new_string === 'string')
    return 'edit'
  if (typeof input.file_path === 'string' && typeof input.content === 'string') return 'write'
  return 'generic'
}

function multiEditLines(edits: unknown): DiffLine[] {
  if (!Array.isArray(edits)) return []
  const hunks = edits
    .filter(isMap)
    .map((e) => diffLines(e.old_string, e.new_string))
    .filter((h) => h.length > 0)
  const out: DiffLine[] = []
  hunks.forEach((h, idx) => {
    if (idx > 0) out.push({ op: 'gap', text: '' })
    out.push(...h)
  })
  return out
}

function chatDiffLineMaps(input: unknown): DiffLine[] {
  switch (classify(input)) {
    case 'edit':
      return diffLines((input as Record<string, unknown>).old_string, (input as Record<string, unknown>).new_string)
    case 'write':
      return diffLines('', (input as Record<string, unknown>).content)
    case 'multi_edit':
      return multiEditLines((input as Record<string, unknown>).edits)
    default:
      return []
  }
}

/* ── chat-tool-diff ────────────────────────────────────────────────────────── */

const CHAT_DIFF_BUDGET = 20

function rowStyle(op: string): string {
  switch (op) {
    case '+':
      return 'color: var(--ok); background: var(--ok-soft); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;'
    case '-':
      return 'color: var(--danger); background: var(--danger-soft); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;'
    case 'gap':
      return 'border-top: 1px solid var(--border-muted); margin: 4px 0; height: 0;'
    default:
      return 'color: var(--fg-dim); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;'
  }
}

function rowPrefix(op: string): string {
  switch (op) {
    case '+':
      return '+ '
    case '-':
      return '- '
    case 'gap':
      return ''
    default:
      return '&nbsp;&nbsp;'
  }
}

function diffRowsHtml(lines: DiffLine[]): string {
  return lines
    .map((l) => `<div style="${rowStyle(l.op)}">${rowPrefix(l.op)}${escapeHtml(l.text)}</div>`)
    .join('')
}

const chatToolDiff: Emit = (block) => {
  const lines = chatDiffLineMaps(block.input)
  if (lines.length === 0) return ''
  const added = lines.filter((l) => l.op === '+').length
  const removed = lines.filter((l) => l.op === '-').length
  const head = lines.slice(0, CHAT_DIFF_BUDGET)
  const rest = lines.slice(CHAT_DIFF_BUDGET)

  const counts =
    `<div class="text-dim" style="font-size: 11px; margin-bottom: 4px;">` +
    `<span style="color: var(--ok);">+${added}</span> ` +
    `<span style="color: var(--danger);">−${removed}</span></div>`

  let body: string
  if (lines.length > CHAT_DIFF_BUDGET) {
    const overflow = lines.length - CHAT_DIFF_BUDGET
    body =
      `<details><summary style="cursor: pointer; list-style: none;">` +
      diffRowsHtml(head) +
      `<div class="text-dim" style="font-size: 11px; padding: 1px 0;">… +${overflow} more lines</div>` +
      `</summary>${diffRowsHtml(rest)}</details>`
  } else {
    body = diffRowsHtml(head)
  }

  return (
    `<div class="bp-chat-tool-diff text-xs" style="font-family: var(--font-mono); margin: 4px 0 0 16px; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;">` +
    counts +
    body +
    `</div>`
  )
}

/* ── chat-todo ─────────────────────────────────────────────────────────────── */

function todoGlyph(status: string): string {
  if (status === 'completed') return '☒'
  if (status === 'in_progress') return '◐'
  return '☐'
}

function glyphStyle(status: string): string {
  if (status === 'completed') return 'flex: none; color: var(--ok);'
  if (status === 'in_progress') return 'flex: none; color: var(--primary);'
  return 'flex: none; opacity: 0.6;'
}

function textStyle(status: string): string {
  if (status === 'completed') return 'overflow-wrap: anywhere; opacity: 0.6; text-decoration: line-through;'
  if (status === 'in_progress') return 'overflow-wrap: anywhere; color: var(--primary); font-weight: 600;'
  return 'overflow-wrap: anywhere;'
}

function todoProgress(todos: unknown[]): string {
  const done = todos.filter((t) => isMap(t) && t.status === 'completed').length
  return `${done}/${todos.length} done`
}

function todoItemHtml(todo: unknown): string {
  const m = isMap(todo) ? todo : {}
  const status = str(m.status) || 'pending'
  const content = str(m.content)
  const activeForm = m.active_form
  const glyph = todoGlyph(status)
  const activeHtml =
    status === 'in_progress' && typeof activeForm === 'string' && activeForm !== ''
      ? `<div class="text-dim" style="padding-left: 20px; opacity: 0.75;">→ ${escapeHtml(activeForm)}</div>`
      : ''
  return (
    `<li class="text-xs"><div style="display: flex; gap: 6px; align-items: baseline;">` +
    `<span aria-hidden="true" style="${glyphStyle(status)}">${glyph}</span>` +
    `<span style="${textStyle(status)}">${escapeHtml(content)}</span></div>${activeHtml}</li>`
  )
}

const chatTodo: Emit = (block) => {
  const todos = asList(block.todos)
  const progress = todos.length === 0 ? '' : ` <span style="opacity: 0.6;"> · ${todoProgress(todos)}</span>`
  const header =
    `<div class="text-xs" style="overflow-wrap: anywhere;">` +
    `<span style="color: var(--primary);">●</span> <span>Update todos</span>${progress}</div>`
  const items =
    todos.length === 0
      ? `<div class="text-xs text-dim" style="padding-left: 16px;">⎿ no items</div>`
      : `<ul style="list-style: none; margin: 4px 0 0; padding: 0 0 0 16px; display: flex; flex-direction: column; gap: 2px;">${todos
          .map(todoItemHtml)
          .join('')}</ul>`
  return `<div class="bp-chat-todo" style="font-family: var(--font-mono);">${header}${items}</div>`
}

/* ── chat-thinking ─────────────────────────────────────────────────────────── */

const chatThinking: Emit = (block) => {
  const tokens = block.tokens
  const label = typeof tokens === 'number' && Number.isInteger(tokens) ? `thought for ~${tokens} tokens` : 'thought'
  return (
    `<div class="bp-chat-thinking text-xs text-dim" style="font-family: var(--font-mono);">` +
    `<span aria-hidden="true">✻</span> ${escapeHtml(label)}</div>`
  )
}

export const chatEmitters: Record<string, Emit> = {
  'chat-tool-diff': chatToolDiff,
  'chat-todo': chatTodo,
  'chat-thinking': chatThinking,
}
