// No reading may make a selftest job's ceiling higher than the one that stands (check/capacity.mjs, ceilingsRaised):
// a job whose reading would is split, and a job split off another stands under the ceiling of the job it came from.
import { describe, expect, it } from 'vitest'
import { ceilingsRaised, INPUT, plan } from '../check/capacity.mjs'
import { SELFTEST_JOBS } from '../check/jobs.mjs'

/** The plan with one selftest reading changed. */
const withReading = (key, change) => plan({ ...INPUT, READINGS: { ...INPUT.READINGS, selftest: { ...INPUT.READINGS.selftest, [key]: { ...INPUT.READINGS.selftest[key], ...change } } } })

describe('the selftest ceilings that stand', () => {
  it('hold every committed reading: none makes its job’s ceiling higher than the one that stands', () => {
    expect(ceilingsRaised()).toEqual([])
    // Every job has a ceiling that stands, its own or the one of the job it was split off.
    for (const j of SELFTEST_JOBS) expect(INPUT.SELFTEST_STANDS[j.key] ?? INPUT.SELFTEST_STANDS[INPUT.READINGS.selftest[j.key].from], j.key).toBeGreaterThan(0)
  })

  it('are red by the job’s name when a reading would raise its ceiling, its own or the one of the job it came from', () => {
    expect(ceilingsRaised(withReading('rest', { seconds: 169 }))).toEqual([
      `the selftest's rest job's reading of 169 s (job ${INPUT.READINGS.selftest.rest.job}) makes its ceiling 254 s, higher than the 252 s that stands: split the job (check/jobs.mjs), never raise a ceiling`,
    ])
    for (const j of SELFTEST_JOBS.filter((x) => INPUT.READINGS.selftest[x.key].from)) {
      const top = INPUT.SELFTEST_STANDS[INPUT.READINGS.selftest[j.key].from]
      const over = Math.floor(top / INPUT.HEADROOM) + 1
      expect(ceilingsRaised(withReading(j.key, { seconds: over })), j.key).toEqual([expect.stringContaining(`the selftest's ${j.key} job's reading of ${over} s`)])
      expect(ceilingsRaised(withReading(j.key, { seconds: over })), j.key).toEqual([expect.stringContaining(`higher than the ${top} s that stands`)])
    }
    // The three jobs' hosted readings before they were split (jobs 137541960510, 137541960578, 137541960598) are red.
    for (const [key, seconds] of [['views', 287], ['rest', 213], ['layers', 186]]) expect(ceilingsRaised(withReading(key, { seconds })), key).toHaveLength(1)
    expect(ceilingsRaised(withReading('states', { from: undefined }))).toEqual([
      "the selftest's states job has no ceiling that stands and was split off no job that has one (check/capacity.mjs, SELFTEST_STANDS)",
    ])
  })
})
