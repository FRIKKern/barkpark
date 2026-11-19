// node build/status.mjs: writes the numbers in README.md and docs/ROADMAP.md
// between <!-- status:start --> and <!-- status:end -->, read from the files
// they count: the part folders, the tokens sheet and package.json's pin.
// `--check` writes nothing and exits 1 when a block is stale; the fast tests
// fail the same way. No number on those pages is typed by hand.
//
// What a check run proves (the lights) is not counted here: it comes from a
// run, not from a file, and the showroom page shows it.
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { discoverParts, partsDir } from './parts.mjs'

export const root = join(import.meta.dirname, '..')
export const START = '<!-- status:start -->'
export const END = '<!-- status:end -->'
export const PAGES = ['README.md', 'docs/ROADMAP.md']
const sheetPath = join(root, '..', '..', '..', 'api', 'priv', 'barkui', 'tokens.css')

const unique = (text, re) => [...new Set([...text.matchAll(re)].map((m) => m[1]))]

/** The facts, read from the files that hold them. */
export function readFacts({ dir = partsDir, sheet = readFileSync(sheetPath, 'utf8'), pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) } = {}) {
  const parts = discoverParts(dir).map((p) => ({ name: p.name, family: p.json.family }))
  return {
    parts,
    skins: unique(sheet, /\[data-skin="([\w-]+)"\]/g),
    surfaces: unique(sheet, /\[data-surface="([\w-]+)"\]/g),
    ui: unique(sheet, /(--ui-[\w-]+)\s*:/g).length,
    bark: unique(sheet, /(--bark-[\w-]+)\s*:/g).length,
    uiSdk: pkg.dependencies['@ui-sdk/web'],
  }
}

const list = (names) => `${names.length}: ${names.join(', ')}`

function byFamily(parts) {
  const families = new Map()
  for (const p of parts) families.set(p.family, [...(families.get(p.family) ?? []), p.name])
  return [...families].sort(([a], [b]) => (a < b ? -1 : 1))
}

/** The block each page carries, by page. */
export function renderBlocks(f) {
  const readme = [
    '| What | Now |',
    '|---|---|',
    `| Parts in the showroom | ${f.parts.length ? list(f.parts.map((p) => p.name)) : '0'} |`,
    `| Skins in the sheet | ${list(f.skins)} |`,
    `| Surfaces a part can sit on | ${list(f.surfaces)} |`,
    `| Colour names in the sheet | ${f.ui} \`--ui-*\` (UI SDK's), ${f.bark} \`--bark-*\` (BarkUI's own) |`,
    `| UI SDK | \`@ui-sdk/web\` ${f.uiSdk}, pinned |`,
  ]
  const families = byFamily(f.parts)
  const roadmap = [
    '| Family | Parts in the showroom |',
    '|---|---|',
    ...(families.length ? families.map(([family, names]) => `| ${family} | ${names.join(', ')} |`) : ['| none yet | |']),
  ]
  return { 'README.md': readme.join('\n'), 'docs/ROADMAP.md': roadmap.join('\n') }
}

/** The page with its block replaced; throws unless it holds exactly one marker pair. */
export function applyBlock(text, block, name = 'page') {
  const a = text.split(START).length - 1
  const b = text.split(END).length - 1
  if (a !== 1 || b !== 1 || text.indexOf(START) > text.indexOf(END)) throw new Error(`${name} needs exactly one ${START} ... ${END} pair`)
  const [head, rest] = text.split(START)
  return `${head}${START}\n${block}\n${END}${rest.split(END)[1]}`
}

/** Pages whose block differs from what the files say. */
export function stalePages({ dir = root, facts = readFacts() } = {}) {
  const blocks = renderBlocks(facts)
  return PAGES.filter((page) => {
    const text = readFileSync(join(dir, page), 'utf8')
    return applyBlock(text, blocks[page], page) !== text
  })
}

if (process.argv[1] === import.meta.filename) {
  try {
    if (process.argv.includes('--check')) {
      const stale = stalePages()
      if (stale.length) {
        console.error(`status: stale in ${stale.join(', ')}; run node build/status.mjs`)
        process.exit(1)
      }
      console.log('status: every block matches')
    } else {
      const blocks = renderBlocks(readFacts())
      for (const page of PAGES) {
        const file = join(root, page)
        const text = readFileSync(file, 'utf8')
        const next = applyBlock(text, blocks[page], page)
        if (next !== text) writeFileSync(file, next)
        console.log(`status: ${page} ${next === text ? 'unchanged' : 'written'}`)
      }
    }
  } catch (e) {
    console.error(`status: ${e.message}`)
    process.exit(1)
  }
}
