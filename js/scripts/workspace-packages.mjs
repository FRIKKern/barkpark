// The js workspace's package set, DERIVED — never enumerated.
//
// WHY THIS FILE EXISTS (task-3cd40ebba5ab106a / task-d4c973367c0d1a76).
// turbo scores a package that has NO SCRIPT for a task as a SUCCESS. Measured
// on 6744725c58d6657b0e90e4767ee17e938b87cf9e: a 4000-key object appended to
// packages/nextjs-query/src/index.ts grew dist/index.mjs from 291 B to
// 238114 B and `turbo run size` still printed "14 successful, 14 total",
// EXIT=0 — because nextjs-query declares no `size` script, so there was no
// task to fail. The same hole swallows `test`: a package with test files and
// no `test` script contributes nothing to "20 successful, 20 total".
//
// A gate cannot therefore be derived from "which packages declare a script" —
// that set IS the defect. It has to be derived from the PACKAGE SET, which is
// what this module produces, and the rules that consume it (see
// check-turbo-task-coverage.mjs) are PREDICATES over each manifest, never a
// list of package names. An enumeration is a snapshot; a predicate is a rule:
// a package added tomorrow is judged on its first run with nothing edited here.
//
// WHY A HAND-ROLLED GLOB. js-tests.yml pins Node 20, where `node:fs`'s
// globSync does not exist (js/vitest.config.mts imports it and dies there —
// task-a9c4b827881d71bd). So the workspace globs are expanded by readdir.
// Only a literal path or a single `*` SEGMENT is supported, and anything else
// — `**`, a `*` inside a segment, a brace — is REFUSED loudly rather than
// quietly matching nothing: a pattern this module cannot expand would shrink
// the package set, and a gate over a silently shrunken set is the exact shape
// of the hole above.

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'

export class DerivationError extends Error {}

/** Parse the `packages:` sequence out of pnpm-workspace.yaml.
 *  Deliberately not a YAML library: this repo's workspace file is a single
 *  top-level key whose value is a flat list of quoted scalars, and adding a
 *  dependency to a CI gate is a lockfile change. A file that does not match
 *  that shape throws rather than yielding an empty list. */
export function readWorkspaceGlobs(jsRoot) {
  const file = join(jsRoot, 'pnpm-workspace.yaml')
  if (!existsSync(file)) {
    throw new DerivationError(`pnpm-workspace.yaml not found at ${file}`)
  }
  const lines = readFileSync(file, 'utf8').split('\n')
  const globs = []
  let inPackages = false
  for (const raw of lines) {
    if (/^packages:\s*$/.test(raw)) {
      inPackages = true
      continue
    }
    if (!inPackages) continue
    const m = /^\s+-\s+(.+?)\s*$/.exec(raw)
    if (m) {
      globs.push(m[1].replace(/^['"]|['"]$/g, ''))
      continue
    }
    if (raw.trim() === '' || raw.startsWith('#')) continue
    break // a new top-level key ends the sequence
  }
  if (globs.length === 0) {
    throw new DerivationError(
      `pnpm-workspace.yaml declared ZERO package globs. A gate derived from an empty ` +
        `workspace proves nothing; refusing to continue.`,
    )
  }
  return globs
}

/** Expand one workspace glob to directories. Literal segments and a whole-segment
 *  `*` only; everything else throws (see the header). */
export function expandGlob(jsRoot, pattern) {
  const segments = pattern.split('/').filter(Boolean)
  for (const seg of segments) {
    if (seg !== '*' && seg.includes('*')) {
      throw new DerivationError(
        `workspace glob ${JSON.stringify(pattern)} uses a pattern this expander cannot ` +
          `resolve (segment ${JSON.stringify(seg)}). Supported: literal segments and a ` +
          `whole-segment '*'. Refusing to under-collect the package set.`,
      )
    }
  }
  let dirs = [jsRoot]
  for (const seg of segments) {
    const next = []
    for (const dir of dirs) {
      if (seg === '*') {
        if (!existsSync(dir)) continue
        for (const ent of readdirSync(dir, { withFileTypes: true })) {
          if (ent.isDirectory() && ent.name !== 'node_modules') next.push(join(dir, ent.name))
        }
      } else {
        const cand = join(dir, seg)
        if (existsSync(cand) && statSync(cand).isDirectory()) next.push(cand)
      }
    }
    dirs = next
  }
  return dirs
}

const TEST_FILE = /\.(test|spec)\.[cm]?[jt]sx?$/
const SKIP_DIR = new Set(['node_modules', 'dist', 'coverage', '.turbo', '.next', '.git'])

/** Every *.test.* / *.spec.* file a package ships, relative to its directory. */
function testFilesUnder(dir, rel = '', out = []) {
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return out
  }
  for (const ent of entries) {
    if (ent.isDirectory()) {
      if (SKIP_DIR.has(ent.name)) continue
      testFilesUnder(join(dir, ent.name), rel ? `${rel}/${ent.name}` : ent.name, out)
    } else if (TEST_FILE.test(ent.name)) {
      out.push(rel ? `${rel}/${ent.name}` : ent.name)
    }
  }
  return out
}

function pointsIntoDist(value) {
  if (typeof value === 'string') return /(^|\/)dist\//.test(value.replace(/^\.\//, './'))
  if (value && typeof value === 'object') return Object.values(value).some(pointsIntoDist)
  return false
}

function hasVitestConfig(dir) {
  try {
    return readdirSync(dir).some((n) => /^vitest[.\w-]*\.config\.[cm]?[jt]s$/.test(n))
  } catch {
    return false
  }
}

/** One record per workspace package, carrying only DERIVED facts. */
export function workspacePackages(jsRoot) {
  const root = resolve(jsRoot)
  const dirs = []
  for (const glob of readWorkspaceGlobs(root)) dirs.push(...expandGlob(root, glob))

  const packages = []
  for (const dir of [...new Set(dirs)].sort()) {
    const manifestPath = join(dir, 'package.json')
    if (!existsSync(manifestPath)) continue
    let pkg
    try {
      pkg = JSON.parse(readFileSync(manifestPath, 'utf8'))
    } catch (err) {
      throw new DerivationError(`${manifestPath} is not readable JSON: ${err?.message ?? err}`)
    }
    const entryFields = [pkg.main, pkg.module, pkg.types, pkg.typings, pkg.exports]
    const declaresLibraryEntry = entryFields.some((v) => v !== undefined && v !== null)
    const files = Array.isArray(pkg.files) ? pkg.files : []
    packages.push({
      name: pkg.name ?? `<unnamed: ${dir}>`,
      dir,
      published: pkg.private !== true,
      // A dist payload is what a consumer installs: either the manifest lists
      // `dist` in `files`, or an entry field resolves into dist/.
      shipsDist: files.includes('dist') || entryFields.some(pointsIntoDist),
      // A CLI: `bin` and no library entry at all. Nothing imports it, so no
      // bundler pulls it in and a byte ceiling measures nothing a consumer
      // pays. MEASURED, and the reason this carve-out is a rule and not a
      // convenience: create-barkpark-app's dist is a Node CLI, and the repo's
      // size-limit preset (@size-limit/preset-small-lib, an esbuild BROWSER
      // bundler) cannot even load it — `ERROR: Could not resolve "node:events"`.
      binOnly: Boolean(pkg.bin) && !declaresLibraryEntry,
      hasSizeScript: typeof pkg.scripts?.size === 'string',
      hasSizeLimitConfig:
        existsSync(join(dir, '.size-limit.json')) ||
        existsSync(join(dir, '.size-limit.js')) ||
        existsSync(join(dir, '.size-limit.mjs')) ||
        Array.isArray(pkg['size-limit']),
      hasTestScript: typeof pkg.scripts?.test === 'string',
      hasVitestConfig: hasVitestConfig(dir),
      testFiles: testFilesUnder(dir),
    })
  }
  if (packages.length === 0) {
    throw new DerivationError(
      `the workspace globs matched ZERO packages under ${root}. A coverage gate over an ` +
        `empty package set is vacuous; refusing to report a pass.`,
    )
  }
  return packages
}

/** Packages that must be reachable by `turbo run size`. */
export function needsSizeBudget(p) {
  return p.published && p.shipsDist && !p.binOnly
}

/** Packages that must be reachable by `turbo run test` / the vitest floor. */
export function needsTestExecution(p) {
  return p.testFiles.length > 0
}
