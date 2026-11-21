#!/usr/bin/env node
// The fast tests hold for every number of real parts the showroom allows, from one up to MOST_PARTS
// (check/jobs.mjs). Each count gets a scratch copy of this package, at its place in a mirror of the repo, whose
// parts/ holds that many real parts: the button and copies of it. One child vitest then runs every fast test file
// in every copy. The tests run as they are written, so one that counts parts by hand turns red at the count it
// breaks. About a minute, so it is not one of the fast tests: `pnpm run test:counts`, and CI's js-tests job runs it
// on every change to this package (walkNeeded).
//
//   node tests/counts.mjs                 walk every count
//   node tests/counts.mjs --since <ref>   walk only when walkNeeded(the files changed since <ref>)
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative, sep } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { copyAs } from '../check/copy.mjs'
import { MOST_PARTS } from '../check/jobs.mjs'
import { FAST_TESTS } from './fast-tests.mjs'

const pkg = fileURLToPath(new URL('..', import.meta.url))
const repoRoot = join(pkg, '..', '..', '..')
const below = relative(repoRoot, pkg)
/** The bound on the child run, inside the walk: past it the walk fails by name. */
export const WALK_SECONDS = 600

/** Whether a change needs the walk: any file under this package, or any file outside js/packages/* and
    js/test-harnesses/* (a workflow, the lockfile, the repo files the tests read). Only a change wholly inside other
    packages is skipped, and an empty or unreadable list walks. */
export function walkNeeded(changed) {
  const files = changed.filter(Boolean)
  return !files.length || files.some((f) => f.startsWith(`${below.split(sep).join('/')}/`) || !/^js\/(packages|test-harnesses)\/[^/]+\//.test(f))
}

/** The files changed since `ref`, as git lists them in the repo at `root`. Without rename detection, so a file moved
    out of this package lists its old path too, and the move counts as a change to this package. */
export function changedSince(ref, root = repoRoot) {
  return execFileSync('git', ['-C', root, 'diff', '--name-only', '--no-renames', `${ref}...HEAD`], { encoding: 'utf8' }).split('\n')
}

/** The child vitest's include: the package's own fast test files (FAST_TESTS, which vitest.config.ts runs too), in
    every copy. */
export const walkInclude = () => FAST_TESTS.map((p) => `n*/${below.split(sep).join('/')}/${p}`)

/** A folder whose entries are links to `from`'s entries, but for `except`, which the caller fills. */
function mirror(from, to, except) {
  mkdirSync(to, { recursive: true })
  for (const e of readdirSync(from)) if (e !== except) symlinkSync(realpathSync(join(from, e)), join(to, e))
}

/** The repo as the tests see it, with this package a copy whose parts/ holds `n` real parts. Everything else is a
    link to the real file, so whatever the code reads from the repo it reads as it is. */
function copyWith(scratch, n) {
  const root = join(scratch, `n${String(n).padStart(2, '0')}`)
  const steps = below.split(sep)
  steps.forEach((step, i) => mirror(join(repoRoot, ...steps.slice(0, i)), join(root, ...steps.slice(0, i)), step))
  const at = join(root, below)
  cpSync(pkg, at, { recursive: true, filter: (src) => ![join(pkg, 'node_modules'), join(pkg, 'parts')].includes(src) })
  mirror(join(pkg, 'node_modules'), join(at, 'node_modules'))
  cpSync(join(pkg, 'parts', 'button'), join(at, 'parts', 'button'), { recursive: true })
  for (let i = 2; i <= n; i++) copyAs(join(at, 'parts', 'button'), `grown${String(i).padStart(2, '0')}-button`)
  return root
}

/** Walks every count; returns the findings, one per red test at a count, or why the walk itself failed. */
export function walk(most = MOST_PARTS) {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-part-counts-'))
  try {
    for (let n = 1; n <= most; n++) copyWith(scratch, n)
    const config = join(scratch, 'vitest.config.mjs')
    writeFileSync(config, `export default { test: { environment: 'node', include: ${JSON.stringify(walkInclude())} } }\n`)
    const out = join(scratch, 'results.json')
    const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('VITEST')))
    const run = spawnSync(process.execPath, [join(pkg, 'node_modules', 'vitest', 'vitest.mjs'), 'run', '--root', scratch, '--config', config, '--reporter=json', `--outputFile=${out}`], { env, encoding: 'utf8', timeout: WALK_SECONDS * 1000 })
    if (run.error?.code === 'ETIMEDOUT') return [`the walk ran past its bound of ${WALK_SECONDS} s`]
    if (!existsSync(out)) return [`the child vitest wrote no results: ${run.stderr.slice(-1000)}`]
    const { testResults } = JSON.parse(readFileSync(out, 'utf8'))
    const count = (r) => relative(scratch, r.name).split(sep)[0]
    const ran = new Set(testResults.map(count))
    const found = []
    if (ran.size !== most) found.push(`the walk ran ${ran.size} of ${most} counts`)
    for (const r of testResults)
      for (const a of r.assertionResults.filter((x) => x.status !== 'passed'))
        found.push(`${count(r)} ${r.name.split(sep).at(-1)}: ${a.fullName}: ${(a.failureMessages?.[0] ?? '').split('\n')[0].slice(0, 300)}`)
    if (!found.length && run.status !== 0) found.push(`the child vitest left with ${run.status}: ${run.stderr.slice(-1000)}`)
    return found
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const at = process.argv.indexOf('--since')
  if (at > 0) {
    const ref = process.argv[at + 1]
    let changed = []
    try {
      changed = changedSince(ref)
    } catch (e) {
      console.log(`counts: the files changed since ${ref} could not be read (${e.message.split('\n')[0]}), so the walk runs`)
    }
    if (!walkNeeded(changed)) {
      console.log(`counts: skipped; every file changed since ${ref} is in another package`)
      process.exit(0)
    }
  }
  const t0 = Date.now()
  const found = walk()
  for (const f of found) console.log(`counts: ${f}`)
  console.log(`counts: ${found.length ? 'FAIL' : 'pass'}, ${MOST_PARTS} counts walked in ${Math.round((Date.now() - t0) / 1000)} s`)
  process.exit(found.length ? 1 : 0)
}
