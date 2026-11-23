// The selftest's row for the closing check's verdict (check/jobs.mjs judge): every result on every leg, in every
// combination, under every plan result and run output, is decided by the one rule. Green only when the plan said
// BarkUI was touched and every leg passed, or said it was not and every leg was skipped; every other combination is
// red with its rows. A fault that shows only when several legs are off at once is red here too. It runs as a direct
// case in its own job's process, where the 781,250 calls have the runner to themselves.
import { JOBS, judge, SELFTEST_JOBS, split } from './jobs.mjs'
import { reportFile, selftestReport } from './selftest-report.mjs'

/** Nine parts, four to a job: three groups, each with its green report, and each selftest job's green report. */
const PARTS = Array.from({ length: 9 }, (_, i) => `x${i}`)
const GROUPS = split(PARTS, 4)
const MATRIX = JSON.stringify(GROUPS.map((g) => ({ group: g.group, of: g.of, parts: g.parts.join(',') })))
const CASES = SELFTEST_JOBS.map((_, i) => `c${i + 1}`)
const REPORTS = [
  ...GROUPS.map((g) => ({ file: `group-${g.group}.json`, data: { group: g.group, of: g.of, parts: g.parts, sha: 'abc', ok: true } })),
  ...SELFTEST_JOBS.map((j, i) => ({ file: reportFile(j.key), data: selftestReport({ key: j.key, sha: 'abc', all: CASES, ran: [CASES[i]], held: [CASES[i]], count: { held: 1, of: 1 } }) })),
]
const RESULTS = ['success', 'failure', 'cancelled', 'skipped', 'missing']

/** Every combination, judged: how many were green and which, if any, broke the rule. */
export function everyCombination(decide = judge) {
  const legs = [JOBS.check, ...SELFTEST_JOBS.map((j) => j.id)]
  const of = Object.fromEntries(RESULTS.map((r) => [r, { result: r }]))
  const all = RESULTS.length ** legs.length
  const wrong = []
  let greens = 0
  let calls = 0
  for (const plan of RESULTS)
    for (const run of ['true', 'false']) {
      const needs = {}
      if (plan !== 'missing') needs[JOBS.plan] = { result: plan, outputs: plan === 'success' ? { run, groups: MATRIX } : {} }
      for (let n = 0; n < all; n++) {
        let x = n
        let success = 0
        let skipped = 0
        for (const id of legs) {
          const r = RESULTS[x % RESULTS.length]
          x = (x - (x % RESULTS.length)) / RESULTS.length
          if (r === 'missing') delete needs[id]
          else needs[id] = of[r]
          success += r === 'success'
          skipped += r === 'skipped'
        }
        const green = plan === 'success' && ((run === 'true' && success === legs.length) || (run === 'false' && skipped === legs.length))
        const v = decide({ needs, reports: REPORTS, names: PARTS, sha: 'abc', perJob: 4 })
        calls++
        greens += v.ok ? 1 : 0
        if ((v.ok !== green || (!v.ok && !(v.rows.length && v.rows.every((r) => r.startsWith('RED '))))) && wrong.length < 3)
          wrong.push(`plan ${plan}, run ${run}, legs ${legs.map((id) => needs[id]?.result ?? 'missing').join(' ')}: ${v.ok ? 'green' : 'red'}`)
      }
    }
  return { calls, greens, wrong, expected: 10 * all }
}

const holds = () => {
  const { calls, greens, wrong, expected } = everyCombination()
  console.log(`    the closing check's verdict: ${calls} of ${expected} combinations judged, ${greens} green (the two the rule allows)${wrong.length ? `; against the rule: ${wrong.join('; ')}` : ''}`)
  return calls === expected && greens === 2 && wrong.length === 0
}

export const VERDICT_CASES = [{ name: "the closing check's verdict: every result on every leg, in every combination, is decided by the one rule", direct: holds }]
