// node build/status.mjs: writes what the sheet and the UI SDK pin hold into
// README.md, between <!-- status:start --> and <!-- status:end -->, with the
// day its numbers last changed and a stamp. It is run by hand until the daily
// news run calls it with the board block; a PR never has to. When the facts
// have not moved, the page is left as it is, date and all.
//
// Parts are not counted here: the showroom page is their one home, so adding a
// part folder changes no other file. The fast tests fail when the block was
// edited by hand or changed shape, never because the tree moved.
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { readStamped, replaceBlock, stamp } from './stamped.mjs'

export const root = join(import.meta.dirname, '..')
export const START = '<!-- status:start -->'
export const END = '<!-- status:end -->'
export const readmePath = join(root, 'README.md')
const sheetPath = join(root, '..', '..', '..', 'api', 'priv', 'barkui', 'tokens.css')

export const HEADER = ['| What | Read from the files |', '|---|---|']
export const LABELS = ['Skins in the sheet', 'Surfaces a part can sit on', 'Colour names in the sheet', 'UI SDK']
const READ = /^Read from the sheet and package\.json; last changed on \d{4}-\d{2}-\d{2}\.$/

const unique = (text, re) => [...new Set([...text.matchAll(re)].map((m) => m[1]))]

/** The facts, read from the files that hold them. */
export function readFacts({ sheet = readFileSync(sheetPath, 'utf8'), pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) } = {}) {
  return {
    skins: unique(sheet, /\[data-skin="([\w-]+)"\]/g),
    surfaces: unique(sheet, /\[data-surface="([\w-]+)"\]/g),
    ui: unique(sheet, /(--ui-[\w-]+)\s*:/g).length,
    bark: unique(sheet, /(--bark-[\w-]+)\s*:/g).length,
    core: pkg.dependencies['@ui-sdk/core'],
    web: pkg.dependencies['@ui-sdk/web'],
  }
}

const exact = (v) => /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(v ?? '')

/** What the pin says, read from package.json: pinned only when both are one exact version. */
export function pinText({ core, web }) {
  if (core === web && exact(web)) return `\`@ui-sdk/core\` and \`@ui-sdk/web\` ${web}, pinned to that exact version`
  return `\`@ui-sdk/core\` ${core}, \`@ui-sdk/web\` ${web}${exact(core) && exact(web) ? ', two different exact versions' : ', not pinned to one exact version'}`
}

const list = (names) => `${names.length}: ${names.join(', ')}`

/** The table rows, without the date. */
export function renderRows(f) {
  return [
    `| ${LABELS[0]} | ${list(f.skins)} |`,
    `| ${LABELS[1]} | ${list(f.surfaces)} |`,
    `| ${LABELS[2]} | ${f.ui} \`--ui-*\` (UI SDK's), ${f.bark} \`--bark-*\` (BarkUI's own) |`,
    `| ${LABELS[3]} | ${pinText(f)} |`,
  ]
}

export function renderStatus(f, day) {
  return stamp([...HEADER, ...renderRows(f), '', `Read from the sheet and package.json; last changed on ${day}.`])
}

/** The block's rows, or a reason it cannot be trusted. */
export function readStatus(text) {
  const r = readStamped(text, START, END)
  if (r.why) return { why: `${r.why}; run node build/status.mjs` }
  const { body } = r
  if (body[0] !== HEADER[0] || body[1] !== HEADER[1]) return { why: 'the table header changed shape' }
  const rows = body.slice(2, -2)
  if (rows.length !== LABELS.length || !rows.every((row, i) => row.startsWith(`| ${LABELS[i]} | `) && row.endsWith(' |'))) return { why: 'the rows are not the ones the script writes, in its order' }
  if (body.at(-2) !== '' || !READ.test(body.at(-1))) return { why: 'the "last changed" line changed shape' }
  return { rows }
}

if (process.argv[1] === import.meta.filename) {
  try {
    const facts = readFacts()
    const text = readFileSync(readmePath, 'utf8')
    const same = JSON.stringify(readStatus(text).rows) === JSON.stringify(renderRows(facts))
    const next = same ? text : replaceBlock(text, START, END, renderStatus(facts, new Date().toISOString().slice(0, 10)))
    if (next !== text) writeFileSync(readmePath, next)
    console.log(`status: README.md ${next === text ? 'unchanged' : 'written'}`)
  } catch (e) {
    console.error(`status: ${e.message}`)
    process.exit(1)
  }
}
