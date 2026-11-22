// The selftest runs as the jobs SELFTEST_JOBS names (check/jobs.mjs); one rule puts each case in one of them. These
// hold that no case falls between the jobs or runs in two, so none can be dropped to make room under a ceiling.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { casesOf, coverCases, NAMES, SELFTEST_JOBS, selftestJob, selftestPick } from '../check/jobs.mjs'
import { readSelftestReports, reportFile, selftestReport } from '../check/selftest-report.mjs'
import { CASES } from '../check/selftest.mjs'

// What each job runs, by the runner's own pick (selftestPick), the one place the selection is made.
const lists = () => Object.fromEntries(SELFTEST_JOBS.map((j) => [j.key, selftestPick(CASES, j.key)]))
const ALL = CASES.map((c) => c.name)
/** The jobs' reports, as each job writes them when every case it picks runs and holds; `change` alters one. */
const reports = (change = (k, r) => r) =>
  SELFTEST_JOBS.map((j) => {
    const ran = selftestPick(CASES, j.key).map((c) => c.name)
    return { file: reportFile(j.key), data: change(j.key, selftestReport({ key: j.key, sha: 'abc', all: ALL, ran, held: ran, count: { held: ran.length, of: ran.length } })) }
  })
const read = (r) => readSelftestReports(r, { sha: 'abc', jobs: SELFTEST_JOBS })
const [A, B] = SELFTEST_JOBS
const NAME_OF = (j) => `the selftest job "${j.name}"`
// The views job's cases as main ran them under the two-job rule, by name.
const VIEWS_BEFORE = [
  'a label not drawn as itself turns both wide lights off at its control, and the ladder holds docs/PARTS.md to its numbers',
  'each drawn reading turns both wide lights off at its own control',
  'each colour that is not one skin variable turns "every skin" off, by name',
  'a demo that patches getComputedStyle, getClientRects and querySelector cannot hide a red label from the trace',
  'an honest decorative dot keeps "every skin" on',
  'every surface read, raised and sunken: a label gone on raised turns both wide lights off at its control',
  'every surface read, primary and inverse: a second skin short on primary and a waited pair measuring worse turn the lights off; a placeholder is matched to a wait by its own colour',
  'a label blanked, edges dropped, and a label and edge gone on raised only, at phone width, turn "phone" off, each by name',
  'a demo that patches getBoundingClientRect cannot pull a button back inside a phone window',
  'an uppercase :HOVER in part.css is pinned like any other, and a longhand left out but set through a variable is read as computed',
]

describe('the selftest jobs', () => {
  it('run every selftest case, each in exactly one job, and as many cases as there are', () => {
    expect(coverCases(lists(), CASES)).toEqual([])
    for (const [key, list] of Object.entries(lists())) expect(list.length, key).toBeGreaterThan(0)
    // The rule gives no key that is not a job, so no case can fall between them.
    expect([...new Set(CASES.map(selftestJob))].sort()).toEqual(SELFTEST_JOBS.map((j) => j.key).sort())
  })

  it('give the views job the same ten cases it ran before the layers job was made', () => {
    expect(selftestPick(CASES, 'views').map((c) => c.name)).toEqual(VIEWS_BEFORE)
  })

  it('send a case that carries `layers` and would fit the views rule to the layers job: layers wins', () => {
    const c = { name: 'x', only: ['skins'] }
    expect(selftestJob(c)).toBe('views')
    expect(selftestJob({ ...c, layers: true })).toBe('layers')
    // And over the rest rule too: a layers case that drives states or reads directly is still a layers case.
    expect(selftestJob({ ...c, layers: true, states: true })).toBe('layers')
    expect(selftestJob({ ...c, layers: true, direct: async () => true })).toBe('layers')
  })

  it('are each named by what they run, and docs/PARTS.md names them as check/jobs.mjs does', () => {
    // No job keeps the bare name "BarkUI selftest": a green job of that name would read as the whole selftest.
    expect(SELFTEST_JOBS.map((j) => j.name)).toEqual([NAMES.selftest, NAMES.selftestRest, NAMES.selftestLayers])
    for (const j of SELFTEST_JOBS) expect(j.name, j.key).toMatch(/^BarkUI selftest, \S/)
    const doc = readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8').replace(/\s+/g, ' ')
    for (const j of SELFTEST_JOBS) expect(doc, j.key).toContain(`"${j.name}" runs \`--job ${j.key}\``)
    expect(doc).not.toMatch(/"BarkUI selftest"/)
  })

  it('have names that are each one case, so a name is a case id', () => {
    expect(new Set(ALL).size).toBe(ALL.length)
    // The pick is casesOf per job, and every case when no job is named.
    for (const j of SELFTEST_JOBS) expect(selftestPick(CASES, j.key)).toEqual(casesOf(CASES, j.key))
    expect(selftestPick(CASES, null)).toEqual(CASES)
  })

  it("the closing check reads every job's report: every case ran once and held", () => {
    expect(read(reports())).toEqual({ rows: [], cases: CASES.length })
  })

  it("a runner that drops a case, or runs one in two jobs, is red in the closing check by the case's name", () => {
    const [first] = selftestPick(CASES, B.key)
    const drop = (k, r) => (k === B.key ? { ...r, ran: r.ran.slice(1), held: r.held.slice(1), count: { held: r.held.length - 1, of: r.ran.length - 1 } } : r)
    expect(read(reports(drop)).rows).toEqual([`selftest case "${first.name}" ran in no selftest job`])
    const twice = (k, r) => (k === A.key ? { ...r, ran: [...r.ran, first.name], held: [...r.held, first.name], count: { held: r.held.length + 1, of: r.ran.length + 1 } } : r)
    expect(read(reports(twice)).rows).toEqual([`selftest case "${first.name}" ran 2 times, in the ${A.key} and ${B.key} jobs`])
  })

  it("a report with another job's key, a count unlike its own list, a case that did not hold, or no report, is red by name", () => {
    expect(read(reports((k, r) => (k === B.key ? { ...r, selftest: A.key } : r))).rows).toEqual([`${NAME_OF(B)}'s report ${reportFile(B.key)} says it is the selftest job "${A.key}"`])
    const n = selftestPick(CASES, A.key).length
    expect(read(reports((k, r) => (k === A.key ? { ...r, count: { held: n + 1, of: n + 1 } } : r))).rows).toEqual([`${NAME_OF(A)} said ${n + 1} of ${n + 1} cases held, but its report lists ${n} held of ${n} run`])
    const [lost] = selftestPick(CASES, A.key)
    expect(read(reports((k, r) => (k === A.key ? { ...r, held: r.held.slice(1), count: { held: n - 1, of: n } } : r))).rows).toEqual([`selftest case "${lost.name}" did not hold in ${NAME_OF(A)}`])
    expect(read(reports().slice(1)).rows).toEqual([`${NAME_OF(A)} left no report`])
    expect(read(reports((k, r) => ({ ...r, sha: 'old' }))).rows).toEqual(SELFTEST_JOBS.map((j) => `${NAME_OF(j)}'s report is from commit old, not abc`))
  })

  it('a case left out, or run in two jobs, is red by its name', () => {
    const l = lists()
    const [a, b] = SELFTEST_JOBS.map((j) => j.key)
    const one = l[a][0]
    expect(coverCases({ ...l, [a]: l[a].slice(1) }, CASES)).toEqual([`"${one.name}": no selftest job runs it`, `the selftest jobs run ${CASES.length - 1} cases, and there are ${CASES.length}`])
    expect(coverCases({ ...l, [b]: [...l[b], one] }, CASES)).toEqual([`"${one.name}": the ${a} and ${b} jobs each run it`, `the selftest jobs run ${CASES.length + 1} cases, and there are ${CASES.length}`])
    const stray = { name: 'a case that is not in the list' }
    expect(coverCases({ ...l, [a]: [...l[a], stray] }, CASES)).toContain(`the ${a} job runs "${stray.name}", which is no selftest case`)
    // A rule that sends a case to a key no job has drops it: the same red.
    const lost = CASES.filter((c) => c !== one)
    expect(coverCases(Object.fromEntries(SELFTEST_JOBS.map((j) => [j.key, casesOf(lost, j.key)])), CASES)).toContain(`"${one.name}": no selftest job runs it`)
  })
})
