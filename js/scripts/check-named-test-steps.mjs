#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// RULE: a test file that a js-tests step runs by name runs only there.
//
// .github/workflows/js-tests.yml runs a few test files in steps of their own,
// by name (the PortableDoc conformance and pd-golden mirror files). Those files
// used to run a second time inside the all-packages Test step (turbo runs every
// package's `vitest run` at once), where nothing waited on them and a busy
// runner pushed them past their time limits. Now each such file is listed in
// its package's vitest config as NAMED_STEP_FILES, and excludeUnlessNamed()
// (js/test-utils/named-step-files.mjs) leaves it out of any run that does not
// name it.
//
// This script reads the workflow and every workspace package's vitest config
// and holds the rule. Exit 1, naming each file, when:
//   * a file a step runs by name is not in its package's NAMED_STEP_FILES
//     (so the all-packages Test step runs it too);
//   * a NAMED_STEP_FILES entry is run by no step (so nothing runs it at all);
//   * a file is run by name by more than one step;
//   * a named or listed file does not exist;
// Exit 2, "cannot read", never a skip, when the workflow side does not read
// as the known frame (named-test-steps-workflow.mjs):
//   * a run line starts a test runner on a named file, or runs vitest, in any
//     shape but the known line:
//         pnpm --filter <package> exec vitest run <file> [<file> ...] \
//           --reporter=default --reporter=json --outputFile.json="$report"
//   * a named step's whole run block is not one of the two known forms, in
//     both of which the step ends 0 only when vitest's JSON report shows each
//     named file ran at least one test and every test in it passed;
//   * a named step carries anything but `name` and `run`, sits outside the
//     Test step's job, or that job or the workflow differs from the known
//     frame (its keys, the job's `defaults:` block);
//   * a line at workflow or job level is not a plain `key:` line;
//   * a step names GITHUB_ENV or GITHUB_PATH;
//   * a test file path appears anywhere else in the jobs (env, with, matrix);
//   * NAMED_STEP_FILES is written in any shape but one literal array of
//     strings passed to excludeUnlessNamed in the one known `exclude:` line,
//     or sits in a config the package's `test` script does not load;
//   * a package's `test` script uses `--exclude`, or a named file is left out
//     some other way (its path written in the package's config);
//   * the workflow has no single Test step, or the rule has nothing to read.
//
// SCOPE: only .github/workflows/js-tests.yml is read. Other workflows that
// name a test file are out, with the reason: engine-release.yml runs
// @barkpark/engine's two integration files by name, and those skip themselves
// in the all-packages run (describe.skipIf without BARKPARK_ENGINE_RELEASE), so
// no work runs twice; every other named run (doc-gates, console-harness,
// architecture, astro, bp-graph) is a node test outside the js workspace.
//
// Usage:  node scripts/check-named-test-steps.mjs            hold the rule
//         node scripts/check-named-test-steps.mjs --run      hold it, then run
//                                                            each named step's
//                                                            files (pnpm test:named-steps)
//         node scripts/check-named-test-steps.selftest.mjs  prove it can lose

import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { FILE_ARG, WORKFLOW, readWorkflow } from './named-test-steps-workflow.mjs'
import { DerivationError, workspacePackages } from './workspace-packages.mjs'

const JS_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const CONFIG_FILE = /^vitest(?:\.[\w-]+)?\.config\.[cm]?[jt]s$/
const DEFAULT_CONFIGS = [
  'vitest.config.ts',
  'vitest.config.mts',
  'vitest.config.js',
  'vitest.config.mjs',
  'vitest.config.cts',
  'vitest.config.cjs',
]
const LIST_DECL = /^(?:export )?const NAMED_STEP_FILES = \[([^\]]*)\]/m
const LIST_USE =
  /exclude: \[\s*\.\.\.configDefaults\.exclude,\s*\.\.\.excludeUnlessNamed\(NAMED_STEP_FILES, process\.argv, import\.meta\.dirname\),?\s*\]/

function readList(pkg, config) {
  const where = `${pkg.dir}/${config.file}`
  const mentions = (config.text.match(/\bNAMED_STEP_FILES\b/g) || []).length
  if (mentions === 0) return { list: null }
  const shape =
    "one `const NAMED_STEP_FILES = ['tests/…', …]` and one `exclude: [...configDefaults.exclude, ...excludeUnlessNamed(NAMED_STEP_FILES, process.argv, import.meta.dirname)]`"
  const decl = LIST_DECL.exec(config.text)
  if (!decl || mentions !== 2 || !LIST_USE.test(config.text))
    return { cannot: `${where}: NAMED_STEP_FILES is not written as ${shape}` }
  if (!config.isDefault)
    return {
      cannot: `${where}: NAMED_STEP_FILES sits in a config ${pkg.name}'s \`test\` script does not load`,
    }
  const list = []
  for (const item of decl[1]
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)) {
    const m = /^'([^']*)'$/.exec(item) || /^"([^"]*)"$/.exec(item)
    if (!m || !FILE_ARG.test(m[1]))
      return {
        cannot: `${where}: NAMED_STEP_FILES entry ${item} is not a plain quoted test file path`,
      }
    list.push(m[1])
  }
  return { list }
}

/**
 * Hold the rule. packages: [{ name, dir, testScript, configs: [{ file, isDefault, text }], has(file) }].
 * Returns { cannot: string[], problems: string[], named: string[] }.
 */
export function judge(workflowText, packages) {
  const { cannot, runs } = readWorkflow(workflowText)
  const problems = []

  const lists = new Map()
  for (const pkg of packages) {
    if (/(^|\s)--exclude\b/.test(pkg.testScript)) {
      cannot.push(
        `${pkg.dir}/package.json: the \`test\` script uses --exclude; the one known way to leave a named file out is NAMED_STEP_FILES in the vitest config`,
      )
    }
    for (const config of pkg.configs) {
      const r = readList(pkg, config)
      if (r.cannot) cannot.push(r.cannot)
      else if (r.list) lists.set(pkg.name, { list: r.list, where: `${pkg.dir}/${config.file}` })
    }
  }
  if (runs.length === 0 && lists.size === 0) {
    cannot.push(
      `${WORKFLOW}: no step runs a test file by name and no package lists NAMED_STEP_FILES; a rule with nothing to read proves nothing`,
    )
  }

  const byName = new Map(packages.map((p) => [p.name, p]))
  const namedBy = new Map()
  for (const r of runs) {
    const pkg = byName.get(r.pkg)
    const at = `step "${r.step.name ?? '(unnamed)'}" (${WORKFLOW}:${r.n})`
    if (!pkg) {
      problems.push(`${at} names ${r.pkg}, which is no workspace package with a test script`)
      continue
    }
    for (const file of r.files) {
      const key = `${r.pkg} ${file}`
      namedBy.set(key, [...(namedBy.get(key) ?? []), at])
      if (!pkg.has(file)) problems.push(`${key}: run by name in ${at}, but the file does not exist`)
      const entry = lists.get(r.pkg)
      if (entry?.list.includes(file)) continue
      if (pkg.configs.some((c) => c.text.includes(file)) || pkg.testScript.includes(file)) {
        cannot.push(
          `${key}: run by name in ${at}, and its path is written in ${pkg.dir}'s config or test script some other way than NAMED_STEP_FILES`,
        )
      } else {
        problems.push(
          `${key}: run by name in ${at}, and the all-packages Test step runs it again. List it in NAMED_STEP_FILES in ${entry?.where ?? `${pkg.dir}'s vitest config`}`,
        )
      }
    }
  }
  for (const [key, ats] of namedBy)
    if (ats.length > 1)
      problems.push(`${key}: run by name by ${ats.length} steps: ${ats.join('; ')}`)
  for (const [name, { list, where }] of lists) {
    const pkg = byName.get(name)
    for (const file of list) {
      if (!pkg.has(file))
        problems.push(
          `${name} ${file}: listed in NAMED_STEP_FILES (${where}), but the file does not exist`,
        )
      if (!namedBy.has(`${name} ${file}`))
        problems.push(
          `${name} ${file}: listed in NAMED_STEP_FILES (${where}), and no js-tests step runs it by name, so nothing runs it`,
        )
    }
  }
  return { cannot, problems, named: [...namedBy.keys()], runs }
}

function packagesFromDisk(jsRoot) {
  return workspacePackages(jsRoot)
    .filter((p) => p.hasTestScript)
    .map((p) => {
      const testScript = JSON.parse(readFileSync(join(p.dir, 'package.json'), 'utf8')).scripts.test
      const c = /(?:^|\s)(?:-c|--config)[ =](\S+)/.exec(testScript)
      const names = readdirSync(p.dir)
        .filter((f) => CONFIG_FILE.test(f))
        .sort()
      const def = c ? c[1].replace(/^\.\//, '') : DEFAULT_CONFIGS.find((f) => names.includes(f))
      return {
        name: p.name,
        dir: relative(jsRoot, p.dir),
        testScript,
        configs: names.map((file) => ({
          file,
          isDefault: file === def,
          text: readFileSync(join(p.dir, file), 'utf8'),
        })),
        has: (file) => existsSync(join(p.dir, file)),
      }
    })
}

function report({ cannot, problems, named }) {
  if (cannot.length) {
    console.error(
      `check-named-test-steps: CANNOT READ (${cannot.length}); no reading was taken and none is reported as passing:`,
    )
    for (const c of cannot) console.error(`  - ${c}`)
  }
  if (problems.length) {
    console.error(
      `check-named-test-steps: FAIL — a test file a js-tests step runs by name must run only there (${problems.length}):`,
    )
    for (const p of problems) console.error(`  - ${p}`)
  }
  if (cannot.length) return 2
  if (problems.length) return 1
  console.log(
    `check-named-test-steps: OK — ${named.length} file(s), each run by name by one step and left out of the all-packages run: ${named.join(', ')}`,
  )
  return 0
}

// ---------------------------------------------------------------- main
function main(argv) {
  let result
  try {
    const workflowText = readFileSync(resolve(JS_ROOT, '..', WORKFLOW), 'utf8')
    result = judge(workflowText, packagesFromDisk(JS_ROOT))
  } catch (err) {
    if (!(err instanceof DerivationError) && err?.code !== 'ENOENT') throw err
    console.error(`check-named-test-steps: CANNOT READ — ${err.message}`)
    return 2
  }
  const code = report(result)
  if (code !== 0 || !argv.includes('--run')) return code
  let status = 0
  for (const r of result.runs) {
    console.log(
      `\ncheck-named-test-steps --run: pnpm --filter ${r.pkg} exec vitest run ${r.files.join(' ')}`,
    )
    try {
      execFileSync('pnpm', ['--filter', r.pkg, 'exec', 'vitest', 'run', ...r.files], {
        cwd: JS_ROOT,
        stdio: 'inherit',
      })
    } catch (err) {
      status = typeof err.status === 'number' && err.status !== 0 ? err.status : 1
    }
  }
  return status
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2))
}
