// Part discovery. A part is a folder under parts/ holding its own files and
// nothing else needs to know about it: the showroom, the check and the tests
// read the directory. Adding a part never edits a file outside its folder.
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { lintDemo } from './demo-lint.mjs'

export const REQUIRED_FILES = ['part.json', 'part.css', 'example.html', 'press.mjs']
// Optional: demo.mjs, bundled into the showroom when present: `export default function (root)`,
// called with this part's own [data-part] element (wires a demo, never a look).
export const OPTIONAL_FILES = ['demo.mjs']
const JSON_FIELDS = { name: 'string', family: 'string', element: 'string', summary: 'string', imports: 'array' }

export const partsDir = join(import.meta.dirname, '..', 'parts')

export function discoverParts(dir = partsDir) {
  const names = readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
    .map((e) => e.name)
    .sort()
  const parts = names.map((name) => readPart(join(dir, name), name))
  // Ids are unique across the whole showroom page: every part prints only ids
  // under its own name, and no two parts print the same one.
  const owner = new Map()
  for (const p of parts) {
    for (const [, id] of p.example.matchAll(/\sid\s*=\s*["']?([^"'\s>]+)/gi)) {
      if (!id.startsWith(`${p.name}-`)) throw new Error(`parts/${p.name}: example.html id "${id}" must start with "${p.name}-"`)
      if (owner.has(id)) throw new Error(`id "${id}" is printed by both parts/${owner.get(id)} and parts/${p.name}`)
      owner.set(id, p.name)
    }
  }
  return parts
}

function readPart(dir, name) {
  const where = `parts/${name}`
  const missing = REQUIRED_FILES.filter((f) => !existsSync(join(dir, f)))
  if (missing.length) throw new Error(`${where}: missing ${missing.join(', ')} (a part folder needs ${REQUIRED_FILES.join(', ')})`)
  let json
  try {
    json = JSON.parse(readFileSync(join(dir, 'part.json'), 'utf8'))
  } catch (e) {
    throw new Error(`${where}: part.json is not JSON (${e.message})`)
  }
  for (const [key, type] of Object.entries(JSON_FIELDS)) {
    const ok = type === 'array' ? Array.isArray(json[key]) : typeof json[key] === type && json[key].trim() !== ''
    if (!ok) throw new Error(`${where}: part.json needs "${key}" (${type})`)
  }
  if (json.textOnly !== undefined && !(Array.isArray(json.textOnly) && json.textOnly.every((x) => typeof x === 'string' && x)))
    throw new Error(`${where}: part.json "textOnly" must be a list of selectors (controls that draw no boundary)`)
  const steps = (x) => x && typeof x === 'object' && Object.keys(x).every((k) => ['focus', 'click', 'hover', 'leave', 'keys'].includes(k)) && (x.focus || x.click || x.hover || x.leave === true || x.keys?.length) && ['focus', 'click', 'hover'].every((k) => x[k] === undefined || (typeof x[k] === 'string' && x[k])) && (x.leave === undefined || x.leave === true) && (x.keys === undefined || (Array.isArray(x.keys) && x.keys.every((k) => typeof k === 'string' && k)))
  if (json.layers !== undefined && !(Array.isArray(json.layers) && json.layers.every((l) => l && typeof l.box === 'string' && l.box && steps(l.open) && steps(l.close) && Object.keys(l).every((k) => ['box', 'open', 'close'].includes(k)))))
    throw new Error(`${where}: part.json "layers" must be a list of { box, open, close }: the selector of a box the part opens in the top layer, and the real input (focus, click, hover, leave, keys) that opens and closes it`)
  const covered = notCoveredWrong(json, readFileSync(join(dir, 'part.css'), 'utf8'))
  if (covered) throw new Error(`${where}: ${covered}`)
  if ('allow' in json)
    throw new Error(`${where}: part.json "allow" is gone: a part cannot excuse itself; a property beyond the vocabulary is a row in build/vocabulary.mjs EXTRA, with the values it may take`)
  if (json.name !== name) throw new Error(`${where}: part.json names the part ${JSON.stringify(json.name)}; it must be the folder name`)
  // A demo is handed its own part's root and works inside it only.
  const demo = existsSync(join(dir, 'demo.mjs')) ? join(dir, 'demo.mjs') : null
  if (demo && !/export\s+default\s+(async\s+)?function\s*\w*\s*\(\s*root\b/.test(readFileSync(demo, 'utf8')))
    throw new Error(`${where}: demo.mjs must \`export default function (root)\` and work inside that root`)
  if (demo) {
    const styled = lintDemo(readFileSync(demo, 'utf8'), readFileSync(join(dir, 'part.css'), 'utf8'))
    if (styled) throw new Error(`${where}/demo.mjs line ${styled.line}: ${styled.why}`)
  }
  const exampleText = readFileSync(join(dir, 'example.html'), 'utf8')
  const refused = lintExample(exampleText)
  if (refused) throw new Error(`${where}/example.html line ${refused.line}: ${refused.why}`)
  const files = [...REQUIRED_FILES, ...OPTIONAL_FILES].filter((f) => existsSync(join(dir, f)))
  return {
    name,
    dir,
    json,
    css: readFileSync(join(dir, 'part.css'), 'utf8'),
    example: readFileSync(join(dir, 'example.html'), 'utf8').trim(),
    press: join(dir, 'press.mjs'),
    demo,
    hash: hashFiles(files.map((f) => [f, readFileSync(join(dir, f))])),
  }
}

// What of its library element a part does not style or prove is a row of part.json "notCovered": { name, why },
// the name of that thing (an element, a feature) and why. The showroom prints the list in one place under the
// part (build/page.mjs). A sentence of the summary or of part.css's notes that says something is not covered
// names a row of the list, so the list is the one place a reader looks.
const NOT_COVERED = /\bnot (styled|covered|proved|judged|on the stage)\b|\bdo(es)? not (style|cover|prove)\b|\b(unstyled|unjudged|unproved)\b/i
/** What is wrong with a part's "notCovered" and the prose beside it, in one sentence; empty when nothing is. */
export function notCoveredWrong(json, css) {
  const list = json.notCovered ?? []
  if (!(Array.isArray(list) && list.every((x) => x && typeof x === 'object' && Object.keys(x).every((k) => k === 'name' || k === 'why') && [x.name, x.why].every((v) => typeof v === 'string' && v.trim()))))
    return 'part.json "notCovered" must be a list of { name, why }: what of its library element the part does not style or prove, and why'
  const twice = list.map((x) => x.name).find((n, i, all) => all.indexOf(n) !== i)
  if (twice) return `part.json "notCovered" names "${twice}" twice`
  const notes = [...css.matchAll(/\/\*([\s\S]*?)\*\//g)].map((m) => m[1]).join(' ')
  for (const [where, prose] of [['part.json "summary"', json.summary ?? ''], ["part.css's notes", notes]]) {
    for (const sentence of prose.replace(/\s+/g, ' ').split(/(?<=[.!?])\s+/)) {
      if (NOT_COVERED.test(sentence) && !list.some((x) => sentence.toLowerCase().includes(x.name.toLowerCase())))
        return `${where} says something is not covered ("${sentence.trim()}"), and part.json "notCovered" names none of it: what a part does not cover is a row of "notCovered", printed under the part`
    }
  }
  return ''
}

// An example is markup only: looks live in part.css, behaviour in demo.mjs.
const EXAMPLE_RULES = [
  [/<style\b/i, 'a <style> element; the look belongs in part.css'],
  [/<script\b/i, 'a <script> element; behaviour belongs in demo.mjs'],
  [/<[^>]*\sstyle\s*=/i, 'a style= attribute; the look belongs in part.css'],
  [/<[^>]*\son[a-z]+\s*=/i, 'an on*= handler; behaviour belongs in demo.mjs'],
  [/<font\b|<[^>]*\s(bgcolor|color|text|link|vlink|alink|background)\s*=/i, 'a presentational colour; the look belongs in part.css'],
  [/<[^>]*\sshadowroot(mode)?\s*=/i, 'a declared shadow root; the check reads the stage, not inside a shadow root'],
  [/<(canvas|iframe|video|audio|object|embed)\b/i, 'an element the check cannot read; draw with markup, inline SVG or an <img>'],
]

/** The first line of an example that holds a look or a behaviour, or null. */
export function lintExample(html) {
  const lines = html.split('\n')
  for (let i = 0; i < lines.length; i++) {
    for (const [re, why] of EXAMPLE_RULES) if (re.test(lines[i])) return { line: i + 1, why }
  }
  return null
}

/** sha256 over named contents, order-independent of the caller. */
export function hashFiles(entries) {
  const h = createHash('sha256')
  for (const [name, body] of [...entries].sort((a, b) => (a[0] < b[0] ? -1 : 1))) h.update(name).update('\0').update(body).update('\0')
  return h.digest('hex').slice(0, 16)
}
