// The check's job split, and the closing check that reads every job's result. CI runs the showroom check as
// jobs side by side: the plan job prints the split (`--matrix`), each job checks its own group
// (`node check/run.mjs --group k --parts …`, which splits again and must agree), and the closing check
// (`--judge`) splits a third time and reads every job's result against it. The split is a pure function of the
// sorted part folder names and PER_JOB (check/capacity.mjs), so all three agree on one checkout. Node only: the
// plan job and the closing check install nothing.
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { PER_JOB } from './capacity.mjs'
import { copyAs } from './copy.mjs'
import { weightOf } from './part-weights.mjs'
import { readSelftestReports } from './selftest-report.mjs'

// The closing check's name in .github/workflows/barkui.yml, written here once; a test holds the workflow to it.
export const AGGREGATE = 'BarkUI showroom check'
// The jobs it reads, by their ids in barkui.yml, and the names they render. Every name here and every group
// name the split can make has a row in .github/required-checks.json (a test holds that too).
export const JOBS = { plan: 'barkui-plan', check: 'barkui-check', selftest: 'barkui-selftest', selftestRest: 'barkui-selftest-rest', selftestLayers: 'barkui-selftest-layers', selftestSurfaces: 'barkui-selftest-surfaces', selftestStates: 'barkui-selftest-states', selftestOpen: 'barkui-selftest-open' }
export const NAMES = {
  plan: 'BarkUI plan (does this change touch it, and which groups)',
  selftest: 'BarkUI selftest, views',
  selftestRest: 'BarkUI selftest, presses, states and refusals',
  selftestLayers: 'BarkUI selftest, top layer and direct readings',
  selftestSurfaces: 'BarkUI selftest, surfaces',
  selftestStates: 'BarkUI selftest, states with their own sheet or part',
  selftestOpen: 'BarkUI selftest, named boxes read open',
  group: (k) => `BarkUI check, group ${k}`,
}

// The selftest runs as six jobs side by side, each with its own ceiling (check/capacity.mjs). Which job runs a
// case is the one rule below, written here once: `views` runs the cases that read the wide or phone views and
// drive no states (their `only` names skins, schemes or phone; no `states`, not `layers`), direct readings among
// them, but for those that read every surface (`surfaces`), which `surfaces` runs; `layers` runs the other direct
// readings (`direct`, each on a page of its own) and the top layer's cases (`layers`), each of which opens its
// boxes by real input or holds a refusal, but for the top layer's cases that bring a sheet of their own (`css`), named boxes read open,
// which `open` runs; `states` runs the states cases that bring a sheet (`css`) or a part (`part`) of their own;
// `rest` runs every other case: presses, the other states cases, refusals and the no-script print. A test holds
// that every case runs in exactly one job and that the six together run every case (coverCases).
export const SELFTEST_JOBS = [
  { key: 'views', id: JOBS.selftest, name: NAMES.selftest },
  { key: 'rest', id: JOBS.selftestRest, name: NAMES.selftestRest },
  { key: 'layers', id: JOBS.selftestLayers, name: NAMES.selftestLayers },
  { key: 'surfaces', id: JOBS.selftestSurfaces, name: NAMES.selftestSurfaces },
  { key: 'states', id: JOBS.selftestStates, name: NAMES.selftestStates },
  { key: 'open', id: JOBS.selftestOpen, name: NAMES.selftestOpen },
]
const VIEWS = ['skins', 'schemes', 'phone']
/** The selftest job that runs a case, by its key. */
const readsViews = (c) => (c.only ?? []).some((l) => VIEWS.includes(l))
export const selftestJob = (c) =>
  c.direct ? (readsViews(c) ? 'views' : 'layers')
  : c.layers ? (c.css ? 'open' : 'layers')
  : c.states ? (c.css || c.part ? 'states' : 'rest')
  : readsViews(c) ? (c.surfaces ? 'surfaces' : 'views')
  : 'rest'
// The jobs that read the views, where no case may open a layer.
const VIEW_JOBS = ['views', 'surfaces']
/** Why case `c` sits in the wrong job, given how its run touched the top layer (`touch`, layers.mjs topLayerTouch):
    a case that opens a layer or holds a layer refusal is a `layers` case and runs in the layers job, and a `layers`
    case does one of the two. Empty when it sits where it belongs. The selftest runner asks this of every case it
    runs, so a new case that forgets the flag is caught by what it does, not by its name. */
export const layerMisplaced = (c, touch) =>
  touch && VIEW_JOBS.includes(selftestJob(c))
    ? `"${c.name}" runs in the ${selftestJob(c)} job, but ${touch}: a case that opens a layer or holds a layer refusal is a layers case and runs in the layers job (check/jobs.mjs)`
    : c.layers && !touch
      ? `"${c.name}" is a layers case, but its run opens no layer and holds no layer refusal`
      : ''
/** The cases the job `key` runs, in their order. */
export const casesOf = (cases, key) => cases.filter((c) => selftestJob(c) === key)
/** The cases one selftest run runs: job `key`'s (every case when `key` is null), narrowed to those whose name holds
    `words`. The runner (check/selftest.mjs) and the fast tests both call this; there is no second copy. */
export const selftestPick = (cases, key, words = '') => (key === null ? cases : casesOf(cases, key)).filter((c) => c.name.includes(words))
/** What is wrong with the jobs' case lists ({ key: cases }) against every case, in plain words; empty when every
    case runs in exactly one job, no job runs anything else, and the jobs run as many cases as there are. */
export function coverCases(lists, cases) {
  const out = []
  const runs = new Map(cases.map((c) => [c, []]))
  for (const [key, list] of Object.entries(lists)) for (const c of list) runs.has(c) ? runs.get(c).push(key) : out.push(`the ${key} job runs "${c.name}", which is no selftest case`)
  for (const [c, keys] of runs) {
    if (!keys.length) out.push(`"${c.name}": no selftest job runs it`)
    if (keys.length > 1) out.push(`"${c.name}": the ${keys.join(' and ')} jobs both run it`)
  }
  const total = Object.values(lists).reduce((n, l) => n + l.length, 0)
  if (total !== cases.length) out.push(`the selftest jobs run ${total} cases, and there are ${cases.length}`)
  return out
}

export const partsDir = join(import.meta.dirname, '..', 'parts')
export const NO_PARTS = 'jobs: there are no part folders, so no job would check anything; a check of no parts is refused, never green'

/** Every part folder, as discovery reads them (build/parts.mjs): directories not starting with a dot, sorted. */
export function folderNames(dir = partsDir) {
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
    .map((e) => e.name)
    .sort()
}

// The most groups, written here once. .github/required-checks.json holds one row for each of groups 1 to
// MOST_GROUPS (a test holds the rows to this number), so the split never makes a group without a row: the parts,
// real and proof copies together, stop at MOST_GROUPS × PER_JOB, and past that the run is refused (docs/PARTS.md says
// what to do then).
export const MOST_GROUPS = 8
export const MOST_PARTS = MOST_GROUPS * PER_JOB
const OUTGROWN = (n) =>
  `jobs: ${n} parts, more than ${MOST_GROUPS} groups of ${PER_JOB} hold (${MOST_PARTS}); raise MOST_GROUPS in check/jobs.mjs and add the new group rows to .github/required-checks.json, as js/packages/barkui/docs/PARTS.md says`

// The proof knob, read here and nowhere else: BARKUI_PROOF_COPIES adds that many copies of the button to the
// real parts, made under a scratch root (never in parts/), so CI can be shown a folder larger than the real one.
// It can only add: every real part stays in the set, and a value it cannot read, or one that takes the parts past
// MOST_PARTS, refuses the run.
export function proofCopies(env = process.env, dir = partsDir) {
  const v = env.BARKUI_PROOF_COPIES
  if (v === undefined || v === '') return 0
  const top = Math.max(0, MOST_PARTS - folderNames(dir).length)
  if (!/^\d+$/.test(v) || Number(v) > top) throw new Error(`jobs: BARKUI_PROOF_COPIES must be a whole number from 0 to ${top} beside these parts, not ${JSON.stringify(v)}`)
  return Number(v)
}
const copyName = (i) => `proof${String(i).padStart(2, '0')}-button`

/** The names the split runs: every real part folder, plus the proof copies when the knob asks for them. */
export function partNames(dir = partsDir, env = process.env) {
  const real = folderNames(dir)
  if (real.length > MOST_PARTS) throw new Error(OUTGROWN(real.length))
  const n = proofCopies(env, dir)
  if (!n) return real
  if (!real.includes('button')) throw new Error('jobs: BARKUI_PROOF_COPIES copies parts/button, and there is none')
  const copies = Array.from({ length: n }, (_, i) => copyName(i + 1))
  const taken = copies.filter((c) => real.includes(c))
  if (taken.length) throw new Error(`jobs: a real part folder already has a proof copy's name: ${taken.join(', ')}`)
  return [...real, ...copies].sort()
}

/** The folder a job builds from: parts/ itself, or, with proof copies, a fresh scratch root holding a copy of
    every real part and the copies beside them. */
export function materialize(dir = partsDir, env = process.env, base = env.RUNNER_TEMP || tmpdir()) {
  const n = proofCopies(env, dir)
  if (!n) return dir
  const into = mkdtempSync(join(base, 'barkui-proof-parts-'))
  for (const name of folderNames(dir)) cpSync(join(dir, name), join(into, name), { recursive: true })
  for (let i = 1; i <= n; i++) copyAs(join(into, 'button'), copyName(i))
  return into
}

/** The folder one job's page is built from (check/check.mjs runCheck, given `names`): a fresh scratch root holding
    a copy of those part folders alone, so the page the job reads prints only the stages it is given. */
export function pageOf(dir, names, base = process.env.RUNNER_TEMP || tmpdir()) {
  const into = mkdtempSync(join(base, 'barkui-job-page-'))
  for (const name of names) cpSync(join(dir, name), join(into, name), { recursive: true })
  return into
}

/** The fewest groups of at most perJob parts, sizes within one of each other, the heaviest parts spread apart. The
    parts are dealt out heaviest first (by `weigh`, check/part-weights.mjs; equal weights by name), in rounds: each
    part goes to the lightest group by summed weight among those holding the fewest parts so far (equal loads: the
    lower group number). Each group lists its parts in name order. A pure function of the names and the weights. */
export function split(names, perJob = PER_JOB, weigh = weightOf) {
  if (!names.length) throw new Error(NO_PARTS)
  if (!(Number.isInteger(perJob) && perJob >= 1)) throw new Error(`jobs: a job must hold at least one part, not ${perJob}`)
  const sorted = [...names].sort()
  const of = Math.ceil(sorted.length / perJob)
  const groups = Array.from({ length: of }, (_, i) => ({ group: i + 1, of, parts: [], load: 0 }))
  const heaviest = [...sorted].sort((a, b) => weigh(b) - weigh(a) || (a < b ? -1 : 1))
  for (const name of heaviest.slice(0, -1)) { // PLANT 1: the lightest part is dealt to no group
    const fewest = Math.min(...groups.map((g) => g.parts.length))
    const g = groups.filter((x) => x.parts.length === fewest).reduce((a, b) => (b.load < a.load ? b : a))
    g.parts.push(name)
    g.load += weigh(name)
  }
  return groups.map(({ group, parts }) => ({ group, of, parts: parts.sort() }))
}

/** What is wrong with a list of groups against the part names, in plain words; empty when every part is run by
    exactly one group, no group runs anything else or nothing, and none holds more than perJob. */
export function cover(groups, names, perJob = PER_JOB) {
  const out = []
  const runs = new Map(names.map((n) => [n, []]))
  for (const g of groups) {
    if (!g.parts.length) out.push(`group ${g.group} runs nothing`)
    if (g.parts.length > perJob) out.push(`group ${g.group} holds ${g.parts.length} parts, more than one job holds (${perJob})`)
    for (const p of g.parts) runs.has(p) ? runs.get(p).push(g.group) : out.push(`group ${g.group} runs ${p}, which is no part folder`)
  }
  for (const [n, ks] of runs) {
    if (!ks.length) out.push(`parts/${n}: no job runs it`)
    if (ks.length > 1) out.push(`parts/${n}: groups ${ks.join(' and ')} both run it`)
  }
  return out
}

const toMatrix = (groups) => groups.map((g) => ({ group: g.group, of: g.of, parts: g.parts.join(',') }))

/** The plan job's list: one matrix entry per group. Throws on no parts or a split that does not cover them. */
export function planMatrix(dir = partsDir, env = process.env) {
  const names = partNames(dir, env)
  const groups = split(names)
  const wrong = cover(groups, names)
  if (wrong.length) throw new Error(`jobs: the split does not cover the parts: ${wrong.join('; ')}`)
  return toMatrix(groups)
}

/** A job's own group, split again from its checkout; refuses when the plan handed it another list. */
export function legGroup(k, given, dir = partsDir, env = process.env) {
  const groups = split(partNames(dir, env))
  const g = groups.find((x) => x.group === k)
  if (!g) throw new Error(`jobs: group ${k} is not in this checkout's split of ${groups.length}`)
  if (given !== g.parts.join(',')) throw new Error(`jobs: the plan gave group ${k} "${given}", but this checkout splits it as "${g.parts.join(',')}"`)
  return g
}

const said = { failure: 'is red', cancelled: 'was cancelled', missing: 'is missing from this run' }
const named = { [JOBS.plan]: 'the plan job', [JOBS.check]: 'the check jobs', ...Object.fromEntries(SELFTEST_JOBS.map((j) => [j.id, `the selftest job "${j.name}"`])) }
const LEGS = [JOBS.check, ...SELFTEST_JOBS.map((j) => j.id)]

/** The closing check. Trusts the jobs' results first and their reports second: a report cannot turn a job that
    failed or was cancelled green, and a report from another group, part list or commit counts as missing. */
export function judge({ needs, reports, names, sha, perJob = PER_JOB }) {
  const result = (id) => needs?.[id]?.result ?? 'missing'
  const state = (id) => said[result(id)] ?? `ended "${result(id)}"`
  const red = (rows) => ({ ok: false, rows: rows.map((r) => `RED ${r}`) })
  if (typeof sha !== 'string' || !sha.trim()) return red(['no commit id to read the reports against; a report is never matched to an empty commit'])
  if (result(JOBS.plan) !== 'success') return red([`${named[JOBS.plan]} ${state(JOBS.plan)}; that is never read as "not touched"`])
  const { run, groups: planned } = needs[JOBS.plan].outputs ?? {}
  const rows = []
  if (run === 'false') {
    for (const id of LEGS) if (result(id) !== 'skipped') rows.push(`${named[id]} ${state(id)}, though the plan said BarkUI was not touched`)
    return rows.length ? red(rows) : { ok: true, rows: ['green: the plan said BarkUI was not touched, and the check jobs and every selftest job were skipped'] }
  }
  if (run !== 'true') return red([`the plan job said run=${JSON.stringify(run)}, neither "true" nor "false"`])
  for (const id of LEGS) {
    const r = result(id)
    if (r === 'skipped') rows.push(`${named[id]} ${id === JOBS.check ? 'were' : 'was'} skipped by mistake: the plan said BarkUI was touched`)
    else if (r !== 'success') rows.push(`${named[id]} ${state(id)}`)
  }
  let expected
  try {
    expected = split(names, perJob)
  } catch (e) {
    return red([...rows, e.message])
  }
  for (const w of cover(expected, names, perJob)) rows.push(`this checkout's split: ${w}`)
  if (planned !== JSON.stringify(toMatrix(expected))) rows.push(`the plan's groups ${planned} differ from this checkout's split ${JSON.stringify(toMatrix(expected))}`)
  for (const r of reports) if (r.error) rows.push(`report ${r.file} cannot be read (${r.error})`)
  const read = reports.filter((r) => !r.error && !r.file.startsWith('selftest-')).map((r) => r.data)
  for (const g of expected) {
    const what = `group ${g.group} of ${g.of} (${g.parts.join(', ')})`
    const mine = read.filter((d) => d?.group === g.group)
    if (!mine.length) rows.push(`${what} is missing: no report`)
    else if (mine.length > 1) rows.push(`${what} reported ${mine.length} times`)
    else if (mine[0].sha !== sha) rows.push(`${what} is missing: its report is from commit ${mine[0].sha}, not ${sha}`)
    else if (!Array.isArray(mine[0].parts) || mine[0].parts.join(',') !== g.parts.join(',')) rows.push(`${what} is missing: its report names ${JSON.stringify(mine[0].parts)}`)
    else if (mine[0].ok !== true) rows.push(`${what} is red`)
  }
  for (const d of read) if (!expected.some((g) => g.group === d?.group)) rows.push(`a report for group ${JSON.stringify(d?.group)}, which this checkout's split does not have`)
  // Each selftest job's report: together they ran every case once, and each held (check/selftest-report.mjs).
  const selftest = readSelftestReports(reports, { sha, jobs: SELFTEST_JOBS })
  rows.push(...selftest.rows)
  if (rows.length) return red(rows)
  return { ok: true, rows: [`green: ${expected.length} group(s) of ${names.length} part(s), each checked once at ${sha}, and every selftest job passed, running each of ${selftest.cases} cases once`] }
}

/** Every report file in a folder (each job uploads one), read or not. */
export function readReports(dir) {
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .sort()
    .map((file) => {
      try {
        return { file, data: JSON.parse(readFileSync(join(dir, file), 'utf8')) }
      } catch (e) {
        return { file, error: e.message.split('\n')[0] }
      }
    })
}

// node check/jobs.mjs --matrix: prints the plan's list as JSON.
// node check/jobs.mjs --judge <reports dir>: the closing check, with NEEDS (the workflow's `toJSON(needs)`) and
// GITHUB_SHA in the environment; prints its rows and exits 1 unless green.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [mode, at] = process.argv.slice(2)
  try {
    if (mode === '--matrix') console.log(JSON.stringify(planMatrix()))
    else if (mode === '--judge') {
      const verdict = judge({ needs: JSON.parse(process.env.NEEDS || '{}'), reports: readReports(at ?? ''), names: partNames(), sha: process.env.GITHUB_SHA ?? '' })
      for (const r of verdict.rows) console.log(r)
      process.exit(verdict.ok ? 0 : 1)
    } else throw new Error('jobs: use --matrix or --judge <reports dir>')
  } catch (e) {
    console.error(`RED ${e.message}`)
    process.exit(1)
  }
}

/** What is wrong with `runs` ({ run: rows }) against the rows of the one case they replace, in plain words; empty
    when each old row is in exactly one run. `kind` names the runs (top-layer, states, …). A case unfolded into runs
    keeps every row it held, so none is dropped to make room. */
export function rowsMoved(old, runs, kind) {
  const wrong = []
  for (const row of old) {
    const in_ = Object.keys(runs).filter((r) => runs[r].includes(row))
    const times = Object.values(runs).reduce((k, rows) => k + rows.filter((x) => x === row).length, 0)
    if (times === 0) wrong.push(`the row "${row}" is in no ${kind} run`)
    else if (in_.length > 1) wrong.push(`the row "${row}" is in ${in_.length} ${kind} runs (${in_.join(', ')})`)
    else if (times > 1) wrong.push(`the row "${row}" is in the ${in_[0]} ${kind} run ${times} times`)
  }
  return wrong
}
