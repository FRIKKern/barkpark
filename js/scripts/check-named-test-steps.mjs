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
//   * a named step, or its job, carries a condition the Test step lacks
//     (`if:`, `needs:`, `continue-on-error:`): a named step must run on every
//     run where the Test step runs, and fail the job when its file fails.
//     js-tests.yml has one `on:` path filter for every step, so no path filter
//     can skip one step and not the other.
// Exit 2, "cannot read", never a skip, when:
//   * a run line starts a test runner on a named file, or runs vitest, in any
//     shape but the one this script knows:
//         pnpm --filter <package> exec vitest run <file> [<file> ...]
//     optionally wrapped as  out="$(<that> 2>&1)"
//     (npx, a cd, a backslash continuation, a matrix value, a partial filter,
//     jest or `node --test` on a test file are all "cannot read");
//   * a named step's whole run block is not one of the known whole forms, in
//     which the file's own exit status is the step's exit status (see
//     CAPTURED_FORM); any other block is refused, by step name;
//   * a named step carries a key other than name and run (if and
//     continue-on-error are compared with the Test step above);
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
import { DerivationError, workspacePackages } from './workspace-packages.mjs'

const JS_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const WORKFLOW = '.github/workflows/js-tests.yml'

const TEST_FILE = /[\w@./-]*\.(?:test|spec)\.[cm]?[jt]sx?\b/
const VITEST_CMD = /(?:^|[\s/;&|(`"'])vitest(?:\s|$|[;&|)`"'])/
const FILE_ARG = /^(?!\.{0,2}\/)(?!.*\/\.\.?\/)[\w@-][\w@./-]*\.(?:test|spec)\.[cm]?[jt]sx?$/
const PKG_ARG = /^(?:@[\w.-]+\/)?[\w.-]+$/
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

const indentOf = (s) => s.length - s.trimStart().length

/** Steps of every job in a workflow, by text: no YAML dependency. */
export function parseWorkflow(text) {
  const lines = text.split('\n')
  const jobsAt = lines.findIndex((l) => /^jobs:\s*$/.test(l))
  const steps = []
  const other = []
  const cannot = []
  if (jobsAt < 0) return { steps, other, cannot: [`${WORKFLOW}: no top-level \`jobs:\` key`] }
  let job = null
  let step = null
  let run = false
  const stepKey = (key, value, n) => {
    step.keys.push(key)
    if (key === 'run') {
      if (/^[|>][-+]?$/.test(value)) run = true
      else step.runLines.push({ n, text: value })
    } else if (key === 'if') step.if = value
    else if (key === 'continue-on-error') step.coe = value
    else if (key === 'name') step.name = value.replace(/^"(.*)"$/, '$1')
    else if (value) other.push({ n, text: value })
  }
  for (let i = jobsAt + 1; i < lines.length; i++) {
    const raw = lines[i]
    const n = i + 1
    const t = raw.trim()
    if (run) {
      if (t === '' || indentOf(raw) > 8) {
        if (t !== '' && !t.startsWith('#')) step.runLines.push({ n, text: t })
        continue
      }
      run = false
    }
    if (t === '' || t.startsWith('#')) continue
    let m
    if ((m = /^ {2}([\w-]+):\s*$/.exec(raw))) {
      job = { id: m[1], if: null, needs: null, coe: null }
      step = null
    } else if (/^\S/.test(raw)) {
      job = step = null
      other.push({ n, text: t })
    } else if (job && (m = /^ {4}(if|needs|continue-on-error):\s*(.*)$/.exec(raw))) {
      job[m[1] === 'continue-on-error' ? 'coe' : m[1]] = m[2].trim()
      step = null
    } else if (job && (m = /^ {6}- ([\w-]+):\s?(.*)$/.exec(raw))) {
      step = { job, n, name: null, if: null, coe: null, keys: [], runLines: [] }
      steps.push(step)
      stepKey(m[1], m[2].trim(), n)
    } else if (step && (m = /^ {8}([\w-]+):\s?(.*)$/.exec(raw))) {
      stepKey(m[1], m[2].trim(), n)
    } else if (/^ {6}- /.test(raw)) {
      cannot.push(`${WORKFLOW}:${n}: a step item this script cannot read: ${t}`)
    } else {
      other.push({ n, text: t })
    }
  }
  return { steps, other, cannot }
}

// The whole run block of a named step must be one of these forms, each one
// ending with the named file's own exit status as the step's exit status.
// (a) the known line alone; (b) the captured form the pd-golden mirror step
// uses. A comment or blank line inside the block is not read.
const CAPTURED_FORM = [
  /^set \+e$/,
  /^out="\$\(pnpm .* 2>&1\)"$/,
  /^status=\$\?$/,
  /^set -e$/,
  /^echo "\$out"$/,
  /^case "\$out" in$/,
  /^\*"No projects matched the filters"\*\)$/,
  /^echo "[^"$`\\]*" >&2$/,
  /^exit 1$/,
  /^;;$/,
  /^esac$/,
  /^exit "\$status"$/,
]

// The only keys a named step may carry. `if` and `continue-on-error` are
// compared with the Test step's own; any other key is refused.
const NAMED_STEP_KEYS = ['name', 'run', 'if', 'continue-on-error']

/** Which known whole form a named step's run block is, or null. */
export function blockForm(texts) {
  if (texts.length === 1 && !texts[0].startsWith('out=') && matchNamedRun(texts[0])) return 'line'
  if (
    texts.length === CAPTURED_FORM.length &&
    CAPTURED_FORM.every((re, i) => re.test(texts[i])) &&
    matchNamedRun(texts[1])
  )
    return 'captured'
  return null
}

/** The one known shape of a named run, or null. */
export function matchNamedRun(text) {
  const wrapped = /^out="\$\((.*) 2>&1\)"$/.exec(text)
  const words = (wrapped ? wrapped[1] : text).split(' ')
  const [pnpm, filter, pkg, exec, vitest, runWord, ...files] = words
  if (
    pnpm !== 'pnpm' ||
    filter !== '--filter' ||
    exec !== 'exec' ||
    vitest !== 'vitest' ||
    runWord !== 'run'
  )
    return null
  if (!PKG_ARG.test(pkg ?? '') || files.length === 0 || !files.every((f) => FILE_ARG.test(f)))
    return null
  return { pkg, files }
}

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
  const { steps, other, cannot } = parseWorkflow(workflowText)
  const problems = []
  const runs = []
  const testSteps = []
  for (const s of steps) {
    for (const l of s.runLines) {
      if (/^pnpm exec turbo run test(\s|$)/.test(l.text) && !l.text.includes('--dry-run'))
        testSteps.push(s)
      const known = matchNamedRun(l.text)
      if (known) runs.push({ ...known, step: s, n: l.n })
      else if (TEST_FILE.test(l.text) || VITEST_CMD.test(l.text)) {
        cannot.push(
          `${WORKFLOW}:${l.n}: starts a test runner in a shape this script cannot read (the one known shape is \`pnpm --filter <package> exec vitest run <file> …\`): ${l.text}`,
        )
      }
    }
  }
  for (const s of new Set(runs.map((r) => r.step))) {
    const name = `step "${s.name ?? '(unnamed)'}" (${WORKFLOW}:${s.n})`
    const extra = s.keys.filter((k) => !NAMED_STEP_KEYS.includes(k))
    if (extra.length) {
      cannot.push(
        `${name}: a named step carries only ${NAMED_STEP_KEYS.join(', ')}; it also has ${extra.join(', ')}; refused`,
      )
    }
    if (!blockForm(s.runLines.map((l) => l.text))) {
      cannot.push(
        `${name}: its run block is not one of the known whole forms (the known line alone, or the captured form of the pd-golden mirror step); refused`,
      )
    }
  }
  for (const l of other) {
    if (TEST_FILE.test(l.text))
      cannot.push(
        `${WORKFLOW}:${l.n}: a test file path outside a run line this script can read: ${l.text}`,
      )
  }
  if (testSteps.length !== 1) {
    cannot.push(
      `${WORKFLOW}: expected exactly one all-packages Test step (\`pnpm exec turbo run test …\`), found ${testSteps.length}`,
    )
  }

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
    const t = testSteps[0]
    if (t) {
      const differs = (a, b) => (a ?? null) !== (b ?? null)
      if (differs(r.step.if, t.if))
        problems.push(
          `${at} has \`if: ${r.step.if}\`; the Test step has ${t.if ? `\`if: ${t.if}\`` : 'none'}, so the named step can skip a run the Test step makes`,
        )
      if (r.step.coe && r.step.coe !== 'false')
        problems.push(
          `${at} has \`continue-on-error: ${r.step.coe}\`; its file could fail without failing the job`,
        )
      for (const k of ['if', 'needs', 'coe']) {
        if (differs(r.step.job[k], t.job[k])) {
          const label = k === 'coe' ? 'continue-on-error' : k
          problems.push(
            `${at}: its job "${r.step.job.id}" has \`${label}: ${r.step.job[k] ?? '(none)'}\`; the Test step's job "${t.job.id}" has \`${label}: ${t.job[k] ?? '(none)'}\``,
          )
        }
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
