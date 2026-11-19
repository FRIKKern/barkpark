// node build/board.mjs <goal-task-id>: writes how far each milestone has come
// into docs/ROADMAP.md, between <!-- board:start --> and <!-- board:end -->,
// read from the task board with `bp task get <id> -o json`.
//
// It needs a signed-in `bp`, so it runs on a machine, by hand until the daily
// news run calls it, and never in a PR check. The goal's id is given on the command line and kept out
// of the repo. The block ends with a stamp over its own lines (build/stamped.mjs);
// the fast tests fail when the block was edited by hand or no longer has the
// shape below, never because the board moved.
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { readStamped, replaceBlock, stamp } from './stamped.mjs'

export const START = '<!-- board:start -->'
export const END = '<!-- board:end -->'
export const roadmapPath = join(import.meta.dirname, '..', 'docs', 'ROADMAP.md')

// The milestones in roadmap order, matched by the start of their board title.
export const MILESTONES = [
  ['M0.5', /^BarkUI proof round\b/, 'Proof round'],
  ['M1', /^BarkUI M1\b/, 'The map'],
  ['M2', /^BarkUI M2\b/, 'One skin everywhere'],
  ['Ready', /^BarkUI Ready\b/, 'The showroom and the first six parts'],
  ['M3', /^BarkUI M3\b/, "Editor menus and Barkdown's tree"],
  ['M4', /^BarkUI M4\b/, 'Blocks are parts'],
  ['M5', /^BarkUI M5\b/, 'Every app wears BarkUI'],
  ['M6', /^BarkUI M6\b/, 'Re-imagining'],
  ['Beside', /^BarkUI groundwork\b/, 'Groundwork: every shared piece has one source'],
]
export const HEADER = ['| Id | Milestone | Done | In progress | Open |', '|---|---|---|---|---|']
const ROW = /^\| ([^|]+) \| ([^|]+) \| \d+ \| \d+ \| \d+ \|$/
// Where each board status counts. A status the board adds later counts as open until it is named here.
export const COUNTS = { done: 'done', in_progress: 'in_progress', open: 'open', blocked: 'open', cancelled: null }
export const countOf = (status) => (status in COUNTS ? COUNTS[status] : 'open')
const READ = /^Read from the board; numbers last changed on \d{4}-\d{2}-\d{2}\.$/

const bpTask = (id) => JSON.parse(execFileSync('bp', ['task', 'get', id, '-o', 'json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }))

/** Done, in progress and open under each milestone. A milestone task with no children counts as one item itself. */
export function collect(goalId, read = bpTask) {
  const goal = read(goalId)
  return MILESTONES.flatMap(([id, title, name]) => {
    const tasks = goal.children.filter((c) => title.test(c.title))
    if (!tasks.length) return []
    const count = { done: 0, in_progress: 0, open: 0 }
    for (const t of tasks) {
      const kids = read(t.doc_id).children ?? []
      for (const k of kids.length ? kids : [t]) {
        const column = countOf(k.lifecycle_status)
        if (column) count[column]++
      }
    }
    return [{ id, name, ...count }]
  })
}

/** The block's lines: the table, the day it was read, and a stamp over both. */
export function renderBoard(rows, day) {
  return stamp([...HEADER, ...renderRows(rows), '', `Read from the board; numbers last changed on ${day}.`])
}

export const renderRows = (rows) => rows.map((r) => `| ${r.id} | ${r.name} | ${r.done} | ${r.in_progress} | ${r.open} |`)

/** The block's rows, or a reason it cannot be trusted. */
export function readBlock(text) {
  const r = readStamped(text, START, END)
  if (r.why) return { why: `${r.why}; run node build/board.mjs <goal-task-id>` }
  const { body } = r
  if (body[0] !== HEADER[0] || body[1] !== HEADER[1]) return { why: 'the table header changed shape' }
  const rows = body.slice(2, -2)
  if (!rows.length || !rows.every((row) => ROW.test(row))) return { why: 'a row changed shape' }
  // Each row names a milestone from MILESTONES, by its id and name, once and in that order.
  const order = rows.map((row) => MILESTONES.findIndex(([id, , name]) => ROW.exec(row)[1] === id && ROW.exec(row)[2] === name))
  if (order.some((i, n) => i < 0 || (n > 0 && i <= order[n - 1]))) return { why: 'the rows are not the milestones the script writes, in its order' }
  if (body.at(-2) !== '' || !READ.test(body.at(-1))) return { why: 'the "last changed" line changed shape' }
  return { rows }
}

if (process.argv[1] === import.meta.filename) {
  const goal = process.argv[2]
  if (!goal) {
    console.error('usage: node build/board.mjs <goal-task-id>   (needs a signed-in bp)')
    process.exit(2)
  }
  try {
    const rows = collect(goal)
    const text = readFileSync(roadmapPath, 'utf8')
    // Same numbers as the block holds: leave it, date and all, so a daily run makes no change.
    const same = JSON.stringify(readBlock(text).rows) === JSON.stringify(renderRows(rows))
    const next = same ? text : replaceBlock(text, START, END, renderBoard(rows, new Date().toISOString().slice(0, 10)))
    if (next !== text) writeFileSync(roadmapPath, next)
    console.log(`board: docs/ROADMAP.md ${next === text ? 'unchanged' : 'written'}`)
  } catch (e) {
    console.error(`board: ${e.message}`)
    process.exit(1)
  }
}
