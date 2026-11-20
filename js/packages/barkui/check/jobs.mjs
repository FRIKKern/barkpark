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

// The closing check's name in .github/workflows/barkui.yml, written here once; a test holds the workflow to it.
export const AGGREGATE = 'BarkUI showroom check'
// The jobs it reads, by their ids in barkui.yml, and the names they render. Every name here and every group
// name the split can make has a row in .github/required-checks.json (a test holds that too).
export const JOBS = { plan: 'barkui-plan', check: 'barkui-check', selftest: 'barkui-selftest' }
export const NAMES = {
  plan: 'BarkUI plan (does this change touch it, and which groups)',
  selftest: 'BarkUI selftest',
  group: (k) => `BarkUI check, group ${k}`,
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
// real and proof copies together, stop at MOST_GROUPS × PER_JOB, and past that the run is refused (the readme says
// what to do then).
export const MOST_GROUPS = 8
export const MOST_PARTS = MOST_GROUPS * PER_JOB
const OUTGROWN = (n) =>
  `jobs: ${n} parts, more than ${MOST_GROUPS} groups of ${PER_JOB} hold (${MOST_PARTS}); raise MOST_GROUPS in check/jobs.mjs and add the new group rows to .github/required-checks.json, as js/packages/barkui/README.md says`

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

/** The fewest groups of at most perJob parts, sizes within one of each other, in name order. */
export function split(names, perJob = PER_JOB) {
  if (!names.length) throw new Error(NO_PARTS)
  if (!(Number.isInteger(perJob) && perJob >= 1)) throw new Error(`jobs: a job must hold at least one part, not ${perJob}`)
  const sorted = [...names].sort()
  const of = Math.ceil(sorted.length / perJob)
  const base = Math.floor(sorted.length / of)
  const extra = sorted.length % of
  const groups = []
  let at = 0
  for (let k = 1; k <= of; k++) {
    const size = base + (k <= extra ? 1 : 0)
    groups.push({ group: k, of, parts: sorted.slice(at, (at += size)) })
  }
  return groups
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
const named = { [JOBS.plan]: 'the plan job', [JOBS.check]: 'the check jobs', [JOBS.selftest]: 'the selftest' }

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
    for (const id of [JOBS.check, JOBS.selftest]) if (result(id) !== 'skipped') rows.push(`${named[id]} ${state(id)}, though the plan said BarkUI was not touched`)
    return rows.length ? red(rows) : { ok: true, rows: ['green: the plan said BarkUI was not touched, and the check jobs and the selftest were skipped'] }
  }
  if (run !== 'true') return red([`the plan job said run=${JSON.stringify(run)}, neither "true" nor "false"`])
  for (const id of [JOBS.check, JOBS.selftest]) {
    const r = result(id)
    if (r === 'skipped') rows.push(`${named[id]} were skipped by mistake: the plan said BarkUI was touched`)
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
  const read = reports.filter((r) => !r.error).map((r) => r.data)
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
  if (rows.length) return red(rows)
  return { ok: true, rows: [`green: ${expected.length} group(s) of ${names.length} part(s), each checked once at ${sha}, and the selftest passed`] }
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
