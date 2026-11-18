// Part discovery. A part is a folder under parts/ holding its own files and
// nothing else needs to know about it: the showroom, the check and the tests
// read the directory. Adding a part never edits a file outside its folder.
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

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
  if (json.name !== name) throw new Error(`${where}: part.json names the part ${JSON.stringify(json.name)}; it must be the folder name`)
  // A demo is handed its own part's root and works inside it only.
  const demo = existsSync(join(dir, 'demo.mjs')) ? join(dir, 'demo.mjs') : null
  if (demo && !/export\s+default\s+(async\s+)?function\s*\w*\s*\(\s*root\b/.test(readFileSync(demo, 'utf8')))
    throw new Error(`${where}: demo.mjs must \`export default function (root)\` and work inside that root`)
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

/** sha256 over named contents, order-independent of the caller. */
export function hashFiles(entries) {
  const h = createHash('sha256')
  for (const [name, body] of [...entries].sort((a, b) => (a[0] < b[0] ? -1 : 1))) h.update(name).update('\0').update(body).update('\0')
  return h.digest('hex').slice(0, 16)
}
