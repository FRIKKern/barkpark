// The selftest runs as two jobs (SELFTEST_JOBS in check/jobs.mjs); one rule puts each case in one of them. These
// hold that no case falls between the jobs or runs in both, so none can be dropped to make room under a ceiling.
import { describe, expect, it } from 'vitest'
import { casesOf, coverCases, SELFTEST_JOBS, selftestJob } from '../check/jobs.mjs'
import { CASES } from '../check/selftest.mjs'

const lists = () => Object.fromEntries(SELFTEST_JOBS.map((j) => [j.key, casesOf(CASES, j.key)]))

describe('the selftest jobs', () => {
  it('run every selftest case, each in exactly one job, and as many cases as there are', () => {
    expect(coverCases(lists(), CASES)).toEqual([])
    for (const [key, list] of Object.entries(lists())) expect(list.length, key).toBeGreaterThan(0)
    // The rule gives no key that is not a job, so no case can fall between them.
    expect([...new Set(CASES.map(selftestJob))].sort()).toEqual(SELFTEST_JOBS.map((j) => j.key).sort())
  })

  it('a case left out, or run in both jobs, is red by its name', () => {
    const l = lists()
    const [a, b] = SELFTEST_JOBS.map((j) => j.key)
    const one = l[a][0]
    expect(coverCases({ ...l, [a]: l[a].slice(1) }, CASES)).toEqual([`"${one.name}": no selftest job runs it`, `the selftest jobs run ${CASES.length - 1} cases, and there are ${CASES.length}`])
    expect(coverCases({ ...l, [b]: [...l[b], one] }, CASES)).toEqual([`"${one.name}": the ${a} and ${b} jobs both run it`, `the selftest jobs run ${CASES.length + 1} cases, and there are ${CASES.length}`])
    const stray = { name: 'a case that is not in the list' }
    expect(coverCases({ ...l, [a]: [...l[a], stray] }, CASES)).toContain(`the ${a} job runs "${stray.name}", which is no selftest case`)
    // A rule that sends a case to a key no job has drops it: the same red.
    const lost = CASES.filter((c) => c !== one)
    expect(coverCases(Object.fromEntries(SELFTEST_JOBS.map((j) => [j.key, casesOf(lost, j.key)])), CASES)).toContain(`"${one.name}": no selftest job runs it`)
  })
})
