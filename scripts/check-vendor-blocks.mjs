#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Vendored-renderer block-coverage gate (charter D80).
//
// The starter templates do not depend on @barkpark/react from npm — they vendor
// a packed tarball (templates/*/vendor/barkpark-react.tgz). That tarball is a
// FROZEN COPY of js/packages/react, so every block type the repo teaches the
// renderer after the pack date silently degrades to `bp-unknown-block` on the
// flagship starter. The observed re-drift interval is thirteen hours, and
// nothing in .github/workflows reads the vendor at all.
//
// This gate is the standing tripwire:
//
//   EXPECTED comes from SOURCE — the keys of registry.ts's DISPATCH map, which
//   is `Object.keys(DISPATCH)` at runtime (REGISTERED_TYPES) but is NOT exported
//   from the built dist, so it cannot be read back out of the tarball.
//
//   ACTUAL comes from PROBING the INSTALLED dist — the exact bytes `npm ci`
//   put in the template's node_modules, rendered through the real
//   renderPortableDocument. Not the source, not the tarball's file list: the
//   thing that actually paints for a stranger on a cold first run.
//
// A registered type that comes back inside a `bp-unknown-block` (or throws) is
// a failure, named. The gate FAILS rather than skips when a template is not
// installed — an unprobed template is not a passing template.
//
// Usage:
//   node scripts/check-vendor-blocks.mjs             # gate both templates
//   node scripts/check-vendor-blocks.mjs --selftest  # prove the gate can fail
//   node scripts/check-vendor-blocks.mjs --template templates/search-starter

import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const REGISTRY = 'js/packages/react/src/blocks/registry.ts'
const TEMPLATES = ['templates/search-starter', 'templates/astro-search-starter']

// ---------------------------------------------------------------------------
// EXPECTED — the registered type set, read out of the TypeScript source.
// ---------------------------------------------------------------------------

/**
 * Collect the top-level keys of the object literal assigned to `constName`.
 * Comment-, string- and nesting-aware; `...spreadName` entries come back as
 * `...spreadName` so the caller can follow them. Deliberately a scanner and not
 * a regex: the emitter maps carry kebab keys, shorthand keys, nested emitter
 * options and prose comments containing braces and commas.
 */
export function parseTopLevelKeys(src, constName) {
  const declRe = new RegExp(`(?:export\\s+)?const\\s+${constName}\\b[^=]*=\\s*\\{`)
  const m = declRe.exec(src)
  if (!m) throw new Error(`const ${constName} = { … } not found`)

  let i = m.index + m[0].length // first char inside the literal
  let depth = 1
  let expectKey = true
  const keys = []

  while (i < src.length && depth > 0) {
    const c = src[i]
    const two = src.slice(i, i + 2)

    if (two === '//') {
      i = src.indexOf('\n', i)
      if (i === -1) break
      continue
    }
    if (two === '/*') {
      const end = src.indexOf('*/', i + 2)
      i = end === -1 ? src.length : end + 2
      continue
    }
    if (c === '"' || c === "'" || c === '`') {
      if (depth === 1 && expectKey) {
        const end = findStringEnd(src, i)
        keys.push(src.slice(i + 1, end))
        expectKey = false
        i = end + 1
        continue
      }
      i = findStringEnd(src, i) + 1
      continue
    }
    if (c === '{' || c === '[' || c === '(') {
      depth += 1
      i += 1
      continue
    }
    if (c === '}' || c === ']' || c === ')') {
      depth -= 1
      i += 1
      continue
    }
    if (c === ',' && depth === 1) {
      expectKey = true
      i += 1
      continue
    }
    if (depth === 1 && expectKey && !/\s/.test(c)) {
      if (src.startsWith('...', i)) {
        const name = /^[A-Za-z0-9_$]+/.exec(src.slice(i + 3))
        keys.push(`...${name ? name[0] : ''}`)
        expectKey = false
        i += 3 + (name ? name[0].length : 0)
        continue
      }
      const ident = /^[A-Za-z0-9_$]+/.exec(src.slice(i))
      if (ident) {
        keys.push(ident[0])
        expectKey = false
        i += ident[0].length
        continue
      }
    }
    i += 1
  }

  if (depth !== 0) throw new Error(`unbalanced object literal for const ${constName}`)
  return keys
}

function findStringEnd(src, start) {
  const quote = src[start]
  let i = start + 1
  while (i < src.length) {
    if (src[i] === '\\') {
      i += 2
      continue
    }
    if (src[i] === quote) return i
    i += 1
  }
  throw new Error('unterminated string literal')
}

/** Resolve `import { fooEmitters } from './foo'` → the source file path. */
export function resolveEmitterImport(src, name, blocksDir) {
  const re = new RegExp(`import\\s*\\{[^}]*\\b${name}\\b[^}]*\\}\\s*from\\s*['"]([^'"]+)['"]`)
  const m = re.exec(src)
  if (!m) throw new Error(`no import found for ${name}`)
  return join(blocksDir, `${m[1].replace(/^\.\//, '')}.ts`)
}

/** The registered block types, derived from source exactly as DISPATCH composes them. */
export function expectedTypes(repoRoot = REPO_ROOT) {
  const registryPath = join(repoRoot, REGISTRY)
  const registrySrc = readFileSync(registryPath, 'utf8')
  const blocksDir = dirname(registryPath)
  const out = new Set()

  for (const key of parseTopLevelKeys(registrySrc, 'DISPATCH')) {
    if (!key.startsWith('...')) {
      out.add(key)
      continue
    }
    const mapName = key.slice(3)
    const file = resolveEmitterImport(registrySrc, mapName, blocksDir)
    for (const t of parseTopLevelKeys(readFileSync(file, 'utf8'), mapName)) {
      if (t.startsWith('...')) throw new Error(`nested spread in ${mapName} — extractor needs widening`)
      out.add(t)
    }
  }
  return [...out].sort()
}

// ---------------------------------------------------------------------------
// ACTUAL — probe the installed dist.
// ---------------------------------------------------------------------------

/**
 * Render one minimal block per type through the real renderer and report the
 * types that degrade. `entry` is a filesystem path to an ESM module exporting
 * `renderPortableDocument`. Returns { unknown: [], threw: [{type, message}] }.
 */
export async function probe(entry, types) {
  const mod = await import(pathToFileURL(entry).href)
  const render = mod.renderPortableDocument
  if (typeof render !== 'function') {
    throw new Error(`${entry} does not export renderPortableDocument`)
  }
  const unknown = []
  const threw = []
  for (const type of types) {
    let html
    try {
      html = render([{ type }])
    } catch (err) {
      threw.push({ type, message: String(err && err.message ? err.message : err) })
      continue
    }
    if (typeof html !== 'string' || html.includes('bp-unknown-block')) unknown.push(type)
  }
  return { unknown, threw }
}

/**
 * The INSTALLED dist for a template — the bytes npm ci actually put on disk.
 * Returns null when the template is not installed (the caller FAILS on null;
 * an unprobed template is never a passing template).
 */
function installedEntry(templateDir) {
  const entry = join(templateDir, 'node_modules/@barkpark/react/dist/server.mjs')
  return existsSync(entry) ? entry : null
}

// ---------------------------------------------------------------------------
// The Node floor — a claim the template makes that its own lock can settle.
//
// search-starter shipped with NO engines field while its lock resolved
// undici@8.9.0 {node: ">=22.19.0"}. Under Node 20 `npm ci` exits 0 with only an
// EBADENGINE warning and the BUILD dies with "webidl.util.markAsUncloneable is
// not a function" — naming neither Node nor a version. A declared floor turns
// that into the one message a stranger can act on.
//
// Only PLAIN `>=X` ranges are compared: evaluating `^20.19.0 || >=22.12.0`
// needs a semver resolver this zero-dependency gate does not have, and a gate
// that guesses is worse than one that says what it measured.
//
// Optional and platform-scoped lock entries (os/cpu-restricted binaries) ARE
// counted, deliberately: package.json `engines` is one declaration for every
// platform, so the floor must cover the platform whose binary demands the most.
// Measured today, neither template's floor comes from such an entry — both are
// driven by an unconditional dependency (undici; @astrojs/compiler-rs).
// ---------------------------------------------------------------------------

const PLAIN_FLOOR = /^>=\s*(\d+(?:\.\d+){0,2})$/

export function parseVersion(v) {
  const parts = String(v).split('.').map((n) => Number.parseInt(n, 10) || 0)
  return [parts[0] || 0, parts[1] || 0, parts[2] || 0]
}

export function compareVersions(a, b) {
  const A = parseVersion(a)
  const B = parseVersion(b)
  for (let i = 0; i < 3; i += 1) {
    if (A[i] !== B[i]) return A[i] < B[i] ? -1 : 1
  }
  return 0
}

/** The highest plain `>=X` node floor in a lockfile, and the package demanding it. */
export function strictestPlainFloor(lock) {
  let best = null
  for (const [name, pkg] of Object.entries(lock.packages || {})) {
    if (name === '') continue // the root is the declaration under test
    const range = pkg && pkg.engines && pkg.engines.node
    const m = range && PLAIN_FLOOR.exec(String(range).trim())
    if (!m) continue
    if (!best || compareVersions(m[1], best.version) > 0) best = { version: m[1], pkg: name, range }
  }
  return best
}

/** Adjudicate a template's declared engines.node against its own lock. */
export function engineVerdict(pkgJson, lock) {
  const required = strictestPlainFloor(lock)
  const declared = pkgJson.engines && pkgJson.engines.node
  if (!required) return { ok: true, note: 'lock declares no plain >= node floor' }
  if (!declared) {
    return {
      ok: false,
      note: `declares NO engines.node while its lock requires >=${required.version} (${required.pkg}) — a Node-20 install exits 0 and the build dies with an unattributable error`,
    }
  }
  const m = PLAIN_FLOOR.exec(String(declared).trim())
  if (!m) {
    return { ok: false, note: `engines.node is "${declared}" — this gate compares plain ">=X" floors only` }
  }
  if (compareVersions(m[1], required.version) < 0) {
    return { ok: false, note: `declares "${declared}" but its lock requires >=${required.version} (${required.pkg})` }
  }
  return { ok: true, note: `declares "${declared}"; lock's strictest plain floor is >=${required.version} (${required.pkg})` }
}

// ---------------------------------------------------------------------------
// Gate
// ---------------------------------------------------------------------------

async function gate(templates) {
  const types = expectedTypes()
  console.log(`expected: ${types.length} registered block types (source: ${REGISTRY})`)

  let failed = 0
  for (const rel of templates) {
    const dir = join(REPO_ROOT, rel)
    if (!existsSync(dir)) {
      console.log(`FAIL ${rel}: template directory does not exist`)
      failed += 1
      continue
    }
    const entry = installedEntry(dir)
    if (!entry) {
      console.log(
        `FAIL ${rel}: @barkpark/react is not installed — nothing to probe.\n` +
          `     run: (cd ${rel} && npm ci) then re-run this gate.`
      )
      failed += 1
      continue
    }
    const verdict = engineVerdict(
      JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')),
      JSON.parse(readFileSync(join(dir, 'package-lock.json'), 'utf8'))
    )
    console.log(`${verdict.ok ? 'ok  ' : 'FAIL'} ${rel} node floor: ${verdict.note}`)
    if (!verdict.ok) failed += 1

    const { unknown, threw } = await probe(entry, types)
    const probed = entry.slice(REPO_ROOT.length + 1)
    if (unknown.length === 0 && threw.length === 0) {
      console.log(`ok   ${rel}: ${types.length}/${types.length} render — probed ${probed}`)
      continue
    }
    failed += 1
    console.log(
      `FAIL ${rel}: ${unknown.length + threw.length}/${types.length} registered types do not render — probed ${probed}`
    )
    if (unknown.length) console.log(`     bp-unknown-block: ${unknown.join(' ')}`)
    for (const t of threw) console.log(`     threw ${t.type}: ${t.message}`)
    console.log(
      `     the vendored tarball is STALE relative to js/packages/react.\n` +
        `     re-pack: (cd js/packages/react && pnpm build && pnpm pack --pack-destination /tmp)\n` +
        `     then copy over templates/*/vendor/barkpark-react.tgz, DELETE each\n` +
        `     package-lock.json and re-run npm install (a bare tarball swap leaves\n` +
        `     the stale integrity pin and a warm cache reinstalls the old bytes).`
    )
  }
  return failed === 0
}

// ---------------------------------------------------------------------------
// Selftest — the gate must be able to fail, proven, not asserted.
// ---------------------------------------------------------------------------

const FIXTURE_MAP = `
import { a } from './a'
export const fooEmitters: Record<string, Emit> = {
  heading,
  // a comment with a brace } and a comma , in it
  h2: headingAtLevel(2),
  'ordered-list': numberedList,
  "quote": blockquote,
  nested: makeThing({ inner: 1, alsoInner: [2, 3] }),
  /* block comment, with } */
  'kebab-key': x,
  trailing,
}
`

const FIXTURE_DISPATCH = `
import { coreEmitters } from './core'
import { mathEmitters } from './math'
const DISPATCH: Record<string, Emit> = {
  ...coreEmitters,
  ...mathEmitters,
  direct: thing,
}
`

async function selftest() {
  const checks = []
  const check = (name, fn) => checks.push({ name, fn })
  const eq = (a, b, what) => {
    const A = JSON.stringify(a)
    const B = JSON.stringify(b)
    if (A !== B) throw new Error(`${what}: got ${A}, want ${B}`)
  }

  check('parseTopLevelKeys reads shorthand, quoted, kebab and nested-value keys', () => {
    eq(parseTopLevelKeys(FIXTURE_MAP, 'fooEmitters'), [
      'heading',
      'h2',
      'ordered-list',
      'quote',
      'nested',
      'kebab-key',
      'trailing',
    ], 'fixture keys')
  })

  check('parseTopLevelKeys does not descend into nested literals', () => {
    const keys = parseTopLevelKeys(FIXTURE_MAP, 'fooEmitters')
    for (const leaked of ['inner', 'alsoInner']) {
      if (keys.includes(leaked)) throw new Error(`leaked nested key ${leaked}`)
    }
  })

  check('parseTopLevelKeys reports spreads so DISPATCH can be followed', () => {
    eq(parseTopLevelKeys(FIXTURE_DISPATCH, 'DISPATCH'), ['...coreEmitters', '...mathEmitters', 'direct'], 'dispatch keys')
  })

  check('resolveEmitterImport maps a spread name to its source file', () => {
    eq(resolveEmitterImport(FIXTURE_DISPATCH, 'mathEmitters', '/b'), '/b/math.ts', 'import path')
  })

  check('parseTopLevelKeys refuses a missing const instead of returning empty', () => {
    let raised = false
    try {
      parseTopLevelKeys(FIXTURE_MAP, 'nopeEmitters')
    } catch {
      raised = true
    }
    if (!raised) throw new Error('a missing const returned quietly — the gate would pass vacuously')
  })

  check('expectedTypes reads the real registry and carries the drift aliases', () => {
    const types = expectedTypes()
    if (types.length < 40) throw new Error(`only ${types.length} types extracted — extractor is under-reading`)
    for (const t of ['heading', 'h1', 'h2', 'h3', 'ordered-list', 'paragraph', 'list']) {
      if (!types.includes(t)) throw new Error(`registered type ${t} missing from expected set`)
    }
  })

  const LOCK = {
    packages: {
      '': { name: 'root' },
      'node_modules/next': { engines: { node: '>=20.9.0' } },
      'node_modules/undici': { engines: { node: '>=22.19.0' } },
      'node_modules/astro': { engines: { node: '^20.19.0 || >=22.12.0' } },
    },
  }

  check('strictestPlainFloor picks the highest plain floor and names its package', () => {
    const f = strictestPlainFloor(LOCK)
    eq([f.version, f.pkg], ['22.19.0', 'node_modules/undici'], 'strictest floor')
  })

  check('strictestPlainFloor ignores || ranges rather than guessing at them', () => {
    const f = strictestPlainFloor({ packages: { 'node_modules/astro': { engines: { node: '^20.19.0 || >=22.12.0' } } } })
    if (f !== null) throw new Error(`evaluated a range it cannot resolve: ${JSON.stringify(f)}`)
  })

  check('engineVerdict FAILS a template that declares no floor at all', () => {
    const v = engineVerdict({ name: 'search-starter' }, LOCK)
    if (v.ok) throw new Error('a template with no engines field passed')
    if (!v.note.includes('22.19.0')) throw new Error(`verdict does not name the required floor: ${v.note}`)
  })

  check('engineVerdict FAILS a floor below what the lock requires', () => {
    const v = engineVerdict({ engines: { node: '>=20' } }, LOCK)
    if (v.ok) throw new Error('>=20 passed against a >=22.19.0 lock')
  })

  check('engineVerdict passes an equal or higher floor', () => {
    if (!engineVerdict({ engines: { node: '>=22.19.0' } }, LOCK).ok) throw new Error('equal floor rejected')
    if (!engineVerdict({ engines: { node: '>=24' } }, LOCK).ok) throw new Error('higher floor rejected')
  })

  check('compareVersions orders by numeric segment, not lexically', () => {
    if (compareVersions('22.9.0', '22.19.0') >= 0) throw new Error('22.9.0 sorted at or above 22.19.0')
  })

  // The load-bearing proof: a dist that unknown-boxes a registered type MUST be
  // caught, and one that renders everything MUST pass. Both arms, real imports.
  const dir = mkdtempSync(join(tmpdir(), 'bp-vendor-gate-'))
  try {
    const stale = join(dir, 'stale.mjs')
    writeFileSync(
      stale,
      `const KNOWN = new Set(['heading', 'paragraph'])
export function renderPortableDocument(blocks) {
  return blocks.map((b) => (KNOWN.has(b.type)
    ? '<p>ok</p>'
    : '<div class="bp-unknown-block">Unsupported block: ' + b.type + '</div>')).join('')
}
`
    )
    const fresh = join(dir, 'fresh.mjs')
    writeFileSync(fresh, `export function renderPortableDocument(blocks) { return blocks.map(() => '<p>ok</p>').join('') }\n`)
    const angry = join(dir, 'angry.mjs')
    writeFileSync(angry, `export function renderPortableDocument() { throw new Error('boom') }\n`)
    const empty = join(dir, 'empty.mjs')
    writeFileSync(empty, `export const nothing = 1\n`)

    const types = ['heading', 'h2', 'ordered-list', 'paragraph']

    check('probe NAMES the unknown-boxed types on a stale dist', async () => {
      const r = await probe(stale, types)
      eq(r.unknown, ['h2', 'ordered-list'], 'stale unknown set')
      eq(r.threw, [], 'stale threw set')
    })

    check('probe passes clean on a dist that renders every registered type', async () => {
      const r = await probe(fresh, types)
      eq(r.unknown, [], 'fresh unknown set')
      eq(r.threw, [], 'fresh threw set')
    })

    check('probe reports a throwing emitter instead of crashing the gate', async () => {
      const r = await probe(angry, types)
      eq(r.threw.map((t) => t.type), types, 'threw types')
      eq(r.threw[0].message, 'boom', 'threw message')
    })

    check('probe refuses a dist with no renderPortableDocument export', async () => {
      let raised = false
      try {
        await probe(empty, types)
      } catch {
        raised = true
      }
      if (!raised) throw new Error('a dist without the renderer probed green')
    })

    let passed = 0
    for (const c of checks) {
      await c.fn()
      passed += 1
      console.log(`ok   ${c.name}`)
    }
    console.log(`selftest ${passed}/${checks.length} passed`)
    return true
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

// ---------------------------------------------------------------------------

async function main() {
  const argv = process.argv.slice(2)
  if (argv.includes('--selftest')) {
    process.exit((await selftest()) ? 0 : 1)
  }
  const idx = argv.indexOf('--template')
  const templates = idx === -1 ? TEMPLATES : [argv[idx + 1]]
  process.exit((await gate(templates)) ? 0 : 1)
}

// Run the gate only when this file IS the entry point. Without this guard the
// exported helpers above cannot be imported — importing them would run the gate
// and call process.exit, which is how a "reusable" module quietly becomes one.
if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  main().catch((err) => {
    console.error(`check-vendor-blocks: ${err && err.stack ? err.stack : err}`)
    process.exit(1)
  })
}
