// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Reads .github/workflows/js-tests.yml for check-named-test-steps.mjs, by
// text, with no YAML dependency. It fails closed: a line it cannot place is
// "cannot read" (exit 2), never skipped.
//
// The frame a named step runs in is pinned to what js-tests.yml has: the
// workflow's top-level keys, the keys and `defaults:` block of the Test step's
// job, and a named step that sits in that job and carries only `name` and
// `run`. Its whole run block is one of two known forms, and in both the step
// ends 0 only when vitest's own JSON report shows that each named file ran at
// least one test and that every test in it passed. No step may write to
// GITHUB_ENV or GITHUB_PATH.

export const WORKFLOW = '.github/workflows/js-tests.yml'
export const TEST_FILE = /[\w@./-]*\.(?:test|spec)\.[cm]?[jt]sx?\b/
export const FILE_ARG = /^(?!\.{0,2}\/)(?!.*\/\.\.?\/)[\w@-][\w@./-]*\.(?:test|spec)\.[cm]?[jt]sx?$/
const VITEST_CMD = /(?:^|[ /;&|(`"'])vitest(?: |$|[;&|)`"'])/
const PKG_ARG = /^(?:@[\w.-]+\/)?[\w.-]+$/
const KEY = '[A-Za-z_][\\w-]*'
// The characters js-tests.yml may hold: LF, U+0020-U+007E, and these three.
const EXTRA_CHARS = ['\u2500', '\u2014', '\u2192']

const WORKFLOW_KEYS = ['concurrency', 'jobs', 'name', 'on']
const JOB_KEYS = ['defaults', 'name', 'runs-on', 'steps', 'timeout-minutes']
const JOB_DEFAULTS = ['      run:', '        working-directory: js']
const STEP_KEYS = ['name', 'run']

const PROOF_FLAGS = ' --reporter=default --reporter=json --outputFile.json="$report"'
export const JQ_PROGRAM =
  '.success == true and .numTotalTests > 0 and .numFailedTests == 0 and .numPendingTests == 0 and .numTodoTests == 0 and (. as $r | $ARGS.positional | length > 0 and all(. as $f | [$r.testResults[] | select(.name | endswith("/" + $f))] | length == 1 and .[0].status == "passed" and (.[0].assertionResults | length > 0 and all(.status == "passed"))))'
export const jqLine = (files) => `jq -e --args '${JQ_PROGRAM}' ${files.join(' ')} < "$report"`
const REPORT = /^report="\$RUNNER_TEMP\/[a-z0-9-]+\.json"$/

const NAMED = Symbol('named line')
const CAPTURED = Symbol('captured named line')
const JQ = Symbol('jq proof')
// The known whole forms of a named step's run block, line by line (trimmed;
// blank lines and shell comments inside the block are not read).
const FORMS = [
  ['line', ['set -e', REPORT, 'rm -f "$report"', NAMED, JQ]],
  [
    'captured',
    [
      REPORT,
      'rm -f "$report"',
      'set +e',
      CAPTURED,
      'status=$?',
      'set -e',
      'echo "$out"',
      'case "$out" in',
      '*"No projects matched the filters"*)',
      /^echo "[^"$`\\]*" >&2$/,
      'exit 1',
      ';;',
      'esac',
      JQ,
      'exit "$status"',
    ],
  ],
]

// Indent and trim count the ASCII space only, as YAML indentation and the
// shell's word splitting of these lines do.
const indentOf = (s) => /^ */.exec(s)[0].length
const spaceTrim = (s) => s.replace(/^ +| +$/g, '')
const sorted = (a) => [...a].sort().join(',')

/** The one known shape of a named run line, or null. */
export function matchNamedRun(text) {
  const wrapped = /^out="\$\((.*) 2>&1\)"$/.exec(text)
  const body = wrapped ? wrapped[1] : text
  if (!body.endsWith(PROOF_FLAGS)) return null
  const words = body.slice(0, -PROOF_FLAGS.length).split(' ')
  const [pnpm, filter, pkg, exec, vitest, run, ...files] = words
  if (pnpm !== 'pnpm' || filter !== '--filter' || exec !== 'exec') return null
  if (vitest !== 'vitest' || run !== 'run' || !PKG_ARG.test(pkg ?? '')) return null
  if (files.length === 0 || !files.every((f) => FILE_ARG.test(f))) return null
  return { pkg, files, wrapped: Boolean(wrapped) }
}

/** Which known whole form a run block is ('line' | 'captured'), or null. */
export function blockForm(texts) {
  for (const [name, form] of FORMS) {
    if (texts.length !== form.length) continue
    let named = null
    const ok = form.every((entry, i) => {
      const t = texts[i]
      if (entry === NAMED || entry === CAPTURED) {
        named = matchNamedRun(t)
        return named !== null && named.wrapped === (entry === CAPTURED)
      }
      if (entry === JQ) return named !== null && t === jqLine(named.files)
      return entry instanceof RegExp ? entry.test(t) : t === entry
    })
    if (ok) return name
  }
  return null
}

/** Decode the workflow as strict UTF-8, naming each line that is not. */
export function decodeWorkflow(input) {
  if (typeof input === 'string') return { text: input, cannot: [] }
  const bytes = new Uint8Array(input)
  const decoder = new TextDecoder('utf-8', { fatal: true })
  const lines = []
  const cannot = []
  for (let start = 0; start <= bytes.length;) {
    let end = bytes.indexOf(0x0a, start)
    if (end < 0) end = bytes.length
    try {
      lines.push(decoder.decode(bytes.subarray(start, end)))
    } catch {
      cannot.push(`${WORKFLOW}:${lines.length + 1}: not valid UTF-8`)
      lines.push('')
    }
    start = end + 1
  }
  return { text: lines.join('\n'), cannot }
}

/** Every character outside LF, U+0020-U+007E and EXTRA_CHARS, by line. */
export function strayChars(text) {
  const out = []
  text.split('\n').forEach((line, i) => {
    let col = 0
    for (const ch of line) {
      col++
      const c = ch.codePointAt(0)
      if ((c >= 0x20 && c <= 0x7e) || EXTRA_CHARS.includes(ch)) continue
      const hex = c.toString(16).toUpperCase().padStart(4, '0')
      out.push(
        `${WORKFLOW}:${i + 1}: character U+${hex} at column ${col} is not one this file may hold`,
      )
    }
  })
  return out
}

/** Top-level keys, jobs and steps of a workflow, by text. */
export function parseWorkflow(text) {
  const lines = text.split('\n')
  const cannot = []
  const topKeys = []
  const steps = []
  const other = []
  const envWrites = []
  let section = null
  let job = null
  let jobKey = null
  let step = null
  let block = false
  const place = (n, t) => cannot.push(`${WORKFLOW}:${n}: a line this script cannot place: ${t}`)
  const stepKey = (n, key, value) => {
    step.keys.push(key)
    if (key === 'run') {
      if (value === '|') block = true
      else if (value && !/^[|>]/.test(value)) step.runLines.push({ n, text: value })
      else step.odd.push({ n, text: `run: ${value}` })
    } else if (key === 'name') step.name = value.replace(/^"(.*)"$/, '$1')
    else if (value) other.push({ n, text: value })
  }
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i]
    const n = i + 1
    const t = spaceTrim(raw)
    const ind = indentOf(raw)
    if (t !== '' && !t.startsWith('#') && /\bGITHUB_(?:ENV|PATH)\b/.test(t)) {
      envWrites.push({ n, step })
    }
    if (step) {
      if (t === '') continue
      if (block && ind > 8) {
        if (raw.includes('\t')) step.odd.push({ n, text: t })
        if (!t.startsWith('#')) step.runLines.push({ n, text: t })
        continue
      }
      block = false
      if (t.startsWith('#')) {
        if (ind > 6) step.odd.push({ n, text: t })
        continue
      }
      if (ind > 6) {
        const m = new RegExp(`^ {8}(${KEY}):(?: (.*))?$`).exec(raw)
        if (m && !raw.includes('\t')) stepKey(n, m[1], m[2] ?? '')
        else {
          step.odd.push({ n, text: t })
          other.push({ n, text: t })
        }
        continue
      }
      step = null
    }
    if (t === '' || t.startsWith('#')) continue
    if (ind === 0) {
      const m = new RegExp(`^(${KEY}):(?: (.*))?$`).exec(raw)
      if (!m) place(n, t)
      section = m?.[1] ?? null
      if (m) topKeys.push(m[1])
      job = jobKey = null
      continue
    }
    if (section !== 'jobs') continue
    if (ind === 2) {
      const m = new RegExp(`^ {2}(${KEY}):$`).exec(raw)
      if (!m) place(n, t)
      job = m ? { id: m[1], keys: [], defaults: [] } : null
      jobKey = null
      continue
    }
    if (!job) {
      place(n, t)
      continue
    }
    if (ind === 4) {
      const m = new RegExp(`^ {4}(${KEY}):(?: (.*))?$`).exec(raw)
      if (!m) place(n, t)
      jobKey = m?.[1] ?? null
      if (m) job.keys.push(m[1])
      if (m?.[2] && jobKey === 'defaults') job.defaults.push(raw)
      else if (m?.[2]) other.push({ n, text: m[2] })
      continue
    }
    if (ind < 4 || !jobKey) {
      place(n, t)
    } else if (jobKey === 'defaults') {
      job.defaults.push(raw)
    } else if (jobKey !== 'steps') {
      other.push({ n, text: t })
    } else {
      const m = new RegExp(`^ {6}- (${KEY}):(?: (.*))?$`).exec(raw)
      if (!m && !/^ {6}- /.test(raw)) {
        place(n, t)
        continue
      }
      step = { job, n, name: null, opener: m?.[1] ?? null, keys: [], runLines: [], odd: [] }
      steps.push(step)
      if (m) stepKey(n, m[1], m[2] ?? '')
      else other.push({ n, text: t })
    }
  }
  return { cannot, topKeys, steps, other, envWrites }
}

/**
 * The workflow side of the rule. Returns { cannot, runs }, where runs are the
 * named run lines ({ pkg, files, step, n }) of steps whose block is readable.
 */
export function readWorkflow(input) {
  const decoded = decodeWorkflow(input)
  const { cannot, topKeys, steps, other, envWrites } = parseWorkflow(decoded.text)
  cannot.unshift(...decoded.cannot, ...strayChars(decoded.text))
  const stepName = (s) => `step "${s.name ?? '(unnamed)'}" (${WORKFLOW}:${s.n})`
  if (sorted(topKeys) !== sorted(WORKFLOW_KEYS)) {
    cannot.push(
      `${WORKFLOW}: top-level keys are ${topKeys.join(', ')}; the known frame is ${WORKFLOW_KEYS.join(', ')}`,
    )
  }
  for (const w of envWrites) {
    cannot.push(
      `${w.step ? stepName(w.step) : `${WORKFLOW}:${w.n}`}: names GITHUB_ENV or GITHUB_PATH (line ${w.n}); refused`,
    )
  }
  const testSteps = steps.filter((s) =>
    s.runLines.some(
      (l) => /^pnpm exec turbo run test( |$)/.test(l.text) && !l.text.includes('--dry-run'),
    ),
  )
  if (testSteps.length !== 1) {
    cannot.push(
      `${WORKFLOW}: expected exactly one all-packages Test step (\`pnpm exec turbo run test …\`), found ${testSteps.length}`,
    )
  }
  const runs = []
  for (const s of steps) {
    const known = s.runLines.map((l) => ({ l, m: matchNamedRun(l.text) })).filter((x) => x.m)
    if (known.length === 0) {
      for (const l of s.runLines) {
        if (TEST_FILE.test(l.text) || VITEST_CMD.test(l.text)) {
          cannot.push(
            `${WORKFLOW}:${l.n}: starts a test runner in a shape this script cannot read: ${l.text}`,
          )
        }
      }
      continue
    }
    const name = stepName(s)
    for (const { l, m } of known) runs.push({ ...m, step: s, n: l.n })
    if (s.opener !== 'name') cannot.push(`${name}: a named step opens with \`- name:\`; refused`)
    for (const o of s.odd) {
      cannot.push(
        `${name}: line ${o.n} is not a \`name:\` or \`run:\` line or a line of a \`run: |\` block: ${o.text}`,
      )
    }
    const extra = s.keys.filter((k) => !STEP_KEYS.includes(k))
    if (extra.length || sorted(s.keys) !== sorted(STEP_KEYS)) {
      cannot.push(
        `${name}: a named step carries only ${STEP_KEYS.join(', ')}, once each; it has ${s.keys.join(', ')}; refused`,
      )
    }
    if (testSteps.length === 1 && s.job !== testSteps[0].job) {
      cannot.push(`${name}: sits in job "${s.job.id}", not in the Test step's job; refused`)
    }
    if (sorted(s.job.keys) !== sorted(JOB_KEYS)) {
      cannot.push(
        `${name}: its job "${s.job.id}" has keys ${s.job.keys.join(', ')}; the known frame is ${JOB_KEYS.join(', ')}`,
      )
    }
    if (s.job.defaults.join('\n') !== JOB_DEFAULTS.join('\n')) {
      cannot.push(
        `${name}: its job "${s.job.id}" has a defaults block other than \`run: working-directory: js\`; refused`,
      )
    }
    if (!blockForm(s.runLines.map((l) => l.text))) {
      cannot.push(
        `${name}: its run block is not one of the known whole forms with the run-time proof; refused`,
      )
    }
  }
  for (const l of other) {
    if (TEST_FILE.test(l.text)) {
      cannot.push(
        `${WORKFLOW}:${l.n}: a test file path outside a run line this script can read: ${l.text}`,
      )
    }
  }
  return { cannot, runs }
}
