#!/usr/bin/env node
// Execution floor for every vitest project declared by js/vitest.config.mts.
//
// WHY THIS EXISTS (#19085). The `react-browser` project extended
// packages/react/vitest.config.ts and, because `extends` MERGES array fields,
// inherited a `setupFiles` entry that resolved one level ABOVE the repo root.
// The setup import aborted, so the project printed
//   Test Files  1 failed (1)   /   Tests  no tests
// on every run and the only real-browser proof of the React renderer executed
// ZERO assertions — for an unknown length of time, caught by no gate.
// js-tests.yml never invokes the root config's projects at all (it runs turbo
// per-package scripts plus core's test:workerd/test:browser), and
// @barkpark/react's own package run picks that file up in the NODE
// environment, so the browser project's silence was invisible.
//
// WHY A PREDICATE AND NOT A LIST. A hand-written list of today's projects goes
// stale the moment someone adds one — which is exactly the shape of the hole
// that hid this. So this script never names a project. It asks VITEST for the
// declared set (`createVitest(...).projects`, so the
// `packages/*/vitest.config.ts` glob is expanded by the same resolver the real
// run uses), runs them, and requires each one to have EXECUTED at least one
// test. Add a project and it is guarded on its first run; delete one and
// nothing here needs editing.
//
// WHY COUNTS AND NOT AN EXIT CODE. `vitest run` exits 1 on an empty suite only
// in SINGLE-project mode. In PROJECTS mode an empty project passes as long as
// a sibling has files — the note already in js-tests.yml records this — so a
// project that collects zero files exits 0 and reports nothing. An exit code
// is therefore not evidence a suite ran. This asserts on the number of tests
// each project actually executed, which catches BOTH shapes:
//   * setup/collection FAILURE  -> files present, 0 tests   (the #19085 shape)
//   * zero matching test files   -> no files at all          (exits 0 silently)
//
// Usage:  node scripts/check-vitest-projects.mjs [--min N]
//   --min N   floor per project (default 1). A floor of 1 is the honest bar:
//             this gate answers "did it run", never "did it run enough".
// Exit 0 = every declared project cleared the floor.
// Exit 1 = at least one declared project is dark, OR a workspace package that
//          ships test files is covered by no declared project (named in the output).
// Exit 2 = the harness itself failed (could not enumerate or could not run) —
//          distinct on purpose, because a broken harness must never read as a
//          pass, and must never read as a project defect either.

import { createVitest } from 'vitest/node'
import { execFileSync } from 'node:child_process'
import { readdirSync, readFileSync, existsSync } from 'node:fs'
import { join, resolve, sep } from 'node:path'
import {
  DerivationError,
  needsTestExecution,
  workspacePackages,
} from './workspace-packages.mjs'

const argv = process.argv.slice(2)
const minIdx = argv.indexOf('--min')
const MIN = minIdx === -1 ? 1 : Number(argv[minIdx + 1])
if (!Number.isInteger(MIN) || MIN < 1) {
  console.error(`check-vitest-projects: --min must be a positive integer, got ${argv[minIdx + 1]}`)
  process.exit(2)
}

/** Project names as vitest itself resolves them, with the browser-instance
 *  suffix (" (chromium)") stripped: `--project` matches the declared name. */
function declaredNames(vitest) {
  return vitest.projects.map((p) => String(p.name).replace(/\s*\([^()]*\)\s*$/, ''))
}

// ---------------------------------------------------------------------------
// PRECONDITIONS, ALSO DERIVED AND NOT LISTED.
//
// Running every project through the ROOT config skips each package's own `test`
// script, so any work that script does BEFORE handing off to vitest never
// happens — and the project then collects a file it cannot load, which this
// gate would report as a defect it is not. @barkpark/pinned-parity is the live
// case: its `test` is `pnpm run prepare:pinned && vitest run`, and without the
// pack step its one test file throws on import.
//
// The fix is a predicate, like the rest of this script: read every workspace
// package's `scripts.test`, and if it CHAINS commands before `vitest`, run that
// prefix first. Nothing here names a package or a script — a new package that
// adopts the same shape is handled on its first run. Only `pnpm|npm run <name>`
// segments are accepted; anything else is reported and skipped rather than
// executed, so this stays a lifecycle hook and never an arbitrary-shell door.
function runDerivedPreconditions(pkgRoot) {
  if (!existsSync(pkgRoot)) return
  for (const dir of readdirSync(pkgRoot, { withFileTypes: true })) {
    if (!dir.isDirectory()) continue
    const cwd = join(pkgRoot, dir.name)
    const manifest = join(cwd, 'package.json')
    if (!existsSync(manifest)) continue
    let pkg
    try {
      pkg = JSON.parse(readFileSync(manifest, 'utf8'))
    } catch {
      continue
    }
    const testScript = pkg?.scripts?.test
    if (typeof testScript !== 'string') continue
    const vitestAt = testScript.search(/\bvitest\b/)
    if (vitestAt <= 0) continue // no prefix, nothing to do
    const prefix = testScript.slice(0, vitestAt).replace(/&&\s*$/, '').trim()
    if (!prefix) continue
    for (const seg of prefix.split('&&').map((x) => x.trim()).filter(Boolean)) {
      const m = /^(pnpm|npm)\s+run\s+([A-Za-z0-9:_-]+)$/.exec(seg)
      if (!m) {
        console.log(`  precondition SKIPPED (not a plain \`pnpm run <script>\`): ${pkg.name}: ${seg}`)
        continue
      }
      console.log(`  precondition: ${pkg.name}: ${m[1]} run ${m[2]}  (derived from its own scripts.test)`)
      try {
        execFileSync(m[1], ['run', m[2]], { cwd, stdio: 'inherit' })
      } catch (err) {
        console.error(
          `check-vitest-projects: HARNESS FAILURE — ${pkg.name}'s own test precondition \`${seg}\` failed; ` +
            'the run below would blame the package for a setup this script could not perform',
        )
        console.error(err?.message ?? err)
        process.exit(2)
      }
    }
  }
}
// Both workspace member roots: packages/* and the private parity harnesses in
// test-harnesses/* (js/pnpm-workspace.yaml).
for (const memberRoot of ['packages', 'test-harnesses']) {
  runDerivedPreconditions(join(process.cwd(), memberRoot))
}

let vitest
let exitCode = 0
try {
  vitest = await createVitest('test', {
    watch: false,
    run: true,
    // Silence vitest's own reporters: this script prints the verdict. `json`
    // would still write a file; an empty reporter list writes nothing.
    reporters: ['dot'],
    // Never let a config smuggle in a pass: passWithNoTests turns the exact
    // failure mode this gate exists to catch back into a green.
    passWithNoTests: false,
  })
} catch (err) {
  console.error('check-vitest-projects: HARNESS FAILURE — could not load js/vitest.config.mts')
  console.error(err?.stack ?? err)
  process.exit(2)
}

const declared = declaredNames(vitest)
if (declared.length === 0) {
  console.error(
    'check-vitest-projects: HARNESS FAILURE — js/vitest.config.mts declared ZERO projects. ' +
      'A floor over an empty set proves nothing; refusing to report a pass.',
  )
  await vitest.close().catch(() => {})
  process.exit(2)
}

console.log(`check-vitest-projects: ${declared.length} declared project(s), floor ${MIN} test(s) each`)
console.log(declared.map((n) => `  declared: ${n}`).join('\n'))

// ---------------------------------------------------------------------------
// RECONCILIATION AGAINST THE WORKSPACE PACKAGE SET (task-d4c973367c0d1a76 c3).
//
// Everything above this point is honest about its own scope and blind past it:
// it guards every project VITEST DECLARES. Nothing bound that declared set to
// the PACKAGE set, and `packages/*/vitest.config.ts` is what makes a package
// declarable at all — so a package with test files and no config was not a
// dark project, it was NO project, and this script printed a SMALLER declared
// count and "OK". Measured on 6744725c58d6657b0e90e4767ee17e938b87cf9e with
// packages/w3probe (a failing test file, no `test` script, no vitest config):
//   check-vitest-projects: 17 declared project(s), floor 1 test(s) each
//   check-vitest-projects: OK — all 17 declared project(s) executed tests.  EXIT=0
// A count that SHRINKS when coverage is lost is not an instrument.
//
// So: derive the package set (scripts/workspace-packages.mjs — pnpm-workspace.yaml,
// not a list here), take every package that SHIPS TEST FILES, and require at
// least one declared project ROOTED INSIDE it. Nothing below names a package;
// a package added tomorrow is reconciled on its first run.
let workspace
try {
  workspace = workspacePackages(process.cwd())
} catch (err) {
  if (!(err instanceof DerivationError)) throw err
  console.error(`check-vitest-projects: HARNESS FAILURE — ${err.message}`)
  await vitest.close().catch(() => {})
  process.exit(2)
}

const projectRoots = vitest.projects.map((p) => resolve(String(p.config?.root ?? process.cwd())))
const unreconciled = workspace
  .filter(needsTestExecution)
  .filter((pkg) => !projectRoots.some((r) => r === pkg.dir || r.startsWith(pkg.dir + sep)))

console.log(
  `check-vitest-projects: reconciled against ${workspace.length} workspace package(s); ` +
    `${workspace.filter(needsTestExecution).length} ship test files`,
)

if (unreconciled.length > 0) {
  console.error('')
  console.error(
    `check-vitest-projects: FAILED — ${unreconciled.length} workspace package(s) ship test ` +
      'files that NO declared vitest project covers. They are not dark projects; they are ' +
      'not projects at all, so the declared count above simply does not mention them:',
  )
  for (const pkg of unreconciled) {
    console.error(
      `  - ${pkg.name} (${pkg.dir}): ${pkg.testFiles.length} test file(s), e.g. ${pkg.testFiles[0]}` +
        (pkg.hasVitestConfig
          ? ' — it HAS a vitest config, but no declared project resolves to it; check that js/vitest.config.mts still globs it'
          : ' — it has NO vitest config, so js/vitest.config.mts cannot glob it. Add vitest.config.ts'),
    )
  }
  console.error('')
  await vitest.close().catch(() => {})
  process.exit(1)
}

/** counts[project] = { tests, files, failedFiles } */
const counts = Object.fromEntries(declared.map((n) => [n, { tests: 0, files: 0, failedFiles: 0 }]))

try {
  await vitest.start()
} catch (err) {
  // A crash mid-run is not a pass. Fall through to the report so a partially
  // populated state still names which projects got nowhere, then fail.
  console.error('check-vitest-projects: vitest run threw — reporting what it managed to execute')
  console.error(err?.stack ?? err)
  exitCode = 1
}

function countTasks(tasks, bucket) {
  for (const t of tasks ?? []) {
    if (t.type === 'test') bucket.tests += 1
    else if (t.tasks) countTasks(t.tasks, bucket)
  }
}

for (const file of vitest.state.getFiles()) {
  // A file's project name carries the same browser-instance suffix.
  const name = String(file.projectName ?? '').replace(/\s*\([^()]*\)\s*$/, '')
  const bucket = counts[name]
  if (!bucket) continue // a file from a project vitest resolved but did not declare
  bucket.files += 1
  if (file.result?.state === 'fail') bucket.failedFiles += 1
  countTasks(file.tasks, bucket)
}

let failedTestCount = 0
for (const file of vitest.state.getFiles()) {
  const walk = (tasks) => {
    for (const t of tasks ?? []) {
      if (t.type === 'test') {
        if (t.result?.state === 'fail') failedTestCount += 1
      } else if (t.tasks) walk(t.tasks)
    }
  }
  walk(file.tasks)
}
const vitestFailures = () => failedTestCount

await vitest.close().catch(() => {})

const dark = []
console.log('')
for (const name of declared) {
  const { tests, files, failedFiles } = counts[name]
  const ok = tests >= MIN
  if (!ok) dark.push({ name, tests, files, failedFiles })
  console.log(
    `  ${ok ? 'ok  ' : 'DARK'}  ${name}: ${tests} test(s) executed across ${files} file(s)` +
      (failedFiles ? ` (${failedFiles} file(s) failed to load or run)` : ''),
  )
}

if (dark.length > 0) {
  console.error('')
  console.error(
    `check-vitest-projects: FAILED — ${dark.length} declared vitest project(s) executed fewer than ${MIN} test(s):`,
  )
  for (const d of dark) {
    const why =
      d.files === 0
        ? 'collected ZERO test files — its `include` matches nothing, and in projects mode that exits 0 silently'
        : d.failedFiles > 0
          ? `collected ${d.files} file(s) but ran ZERO tests — the file(s) failed to load (a broken setupFiles path or import is the #19085 shape)`
          : `collected ${d.files} file(s) but ran only ${d.tests} test(s)`
  console.error(`  - ${d.name}: ${why}`)
  }
  console.error('')
  console.error('A project that executes no assertions proves nothing. Fix it or delete it.')
  process.exit(1)
}

if (exitCode !== 0) process.exit(exitCode)

// THIS GATE DOES NOT JUDGE PASS/FAIL, ON PURPOSE. Whether the assertions
// SUCCEED is owned by the workflow's `Test` step, which runs each package
// through its own script (turbo), with its own preconditions and its own
// per-package project splits. Running every project through the ROOT config in
// one process is a different, more permissive composition: a package whose own
// `test` script runs several projects as SEPARATE commands can, when composed,
// report failures its real gate does not have. @barkpark/nextjs was the live
// case, until js/vitest.config.mts learned to expand a wrapper config into the
// projects it declares instead of flattening them into one environment — the
// CLASS remains, and the next package to adopt a split it does not express as
// sub-config files will reproduce it. Inheriting those would make this check
// red on main from birth and it would be muted within a week, which is how
// gates die. So: vitest's own exit code is
// DISCARDED here (it is exactly the "exit code is not evidence" trap, in the
// other direction), and the verdict above — every declared project executed at
// least `MIN` tests — is the whole contract.
const failedHere = vitestFailures()
console.log('')
if (failedHere > 0) {
  console.log(
    `check-vitest-projects: note — ${failedHere} test(s) failed under the ROOT config composition. ` +
      'Not this gate\'s verdict (the Test step owns pass/fail); reported so it is never a surprise.',
  )
}
console.log(
  `check-vitest-projects: OK — all ${declared.length} declared project(s) executed tests, ` +
    `and every one of ${workspace.filter(needsTestExecution).length} test-shipping workspace package(s) is covered by one.`,
)
process.exit(0)
