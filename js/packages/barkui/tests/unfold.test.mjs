// Every selftest case runs under one limit, and its hosted reading sits under a share of it (check/capacity.mjs).
// Cases that outgrew that share were unfolded into runs (check/unfolded-cases.mjs). These hold that each row of
// the one case is in exactly one run, that the runs together still read what the case read (every surface; every
// light), and that a case with a key the runner does not read, no reading, or a reading over the share is red by
// the case's name.
import { describe, expect, it } from 'vitest'
import { SURFACES } from '../build/page.mjs'
import { CASE_SECONDS, CASE_SHARE, caseLimitsWrong } from '../check/capacity.mjs'
import { CASE_READINGS } from '../check/case-readings.mjs'
import { LIGHT_NAMES } from '../check/check.mjs'
import { rowsMoved } from '../check/jobs.mjs'
import { surfacesOf } from '../check/proofs.mjs'
import { CASES, partOf } from '../check/selftest.mjs'
import { EVERY_RUN_ROWS, STATE_CASES, SURFACE_CASES, SURFACE_PLANTS, UNFOLDED_ROWS } from '../check/unfolded-cases.mjs'

// The rows of each case, as it held them before it was unfolded.
const ONE_CASE = {
  surfaces: [
    'a label gone on raised',
    'a label gone on inverse',
    'a second skin short on primary',
    'the waited pair worse than recorded',
    'a placeholder on another ground stays red',
    'a placeholder in the waited pair is let through by its wait, in an input and in a textarea',
    'no reader puts a child into an element it measures',
  ],
  states: [
    'a hover on a second control of its kind',
    'a hover through :nth-child on a later control',
    'the hover, drawn on every control it applies to',
    'the pin unlike the real state on the control itself',
    'pending held at rest, in every view',
    'pending reached by the steps',
    'a hover that only dark shows',
    'a rule nothing reads',
    'a branch nothing reads, beside one that is read',
    'an uppercase :HOVER the pin never shows',
    'a hover on the host',
    'a tooltip open only while a driven state holds, named by no layer',
    'a box open only after a press step, named by no layer',
  ],
  checked: ['a box checked at rest, blank', 'the pinned checked row, blank', 'a checked change no pinned row shows', 'a click that leaves the stage changed'],
}

describe('an unfolded case', () => {
  it('keeps every row it held, each in exactly one run', () => {
    for (const kind of ['surfaces', 'states', 'checked']) {
      const every = EVERY_RUN_ROWS[kind] ?? []
      expect(rowsMoved(ONE_CASE[kind].filter((r) => !every.includes(r)), UNFOLDED_ROWS[kind], kind), kind).toEqual([])
      expect(every.filter((r) => !ONE_CASE[kind].includes(r)), kind).toEqual([])
    }
  })

  it('holds the rows every surface holds in every surface run, each with a plant on each surface', () => {
    expect(SURFACE_CASES.length).toBe(SURFACES.length - 1)
    expect(SURFACE_PLANTS.length).toBeGreaterThan(0)
    expect(SURFACE_PLANTS.length).toBe(EVERY_RUN_ROWS.surfaces.length * (SURFACES.length - 1))
    for (const row of EVERY_RUN_ROWS.surfaces) expect(SURFACE_CASES.map((c) => SURFACE_PLANTS.some((x) => x.row === row && x.on === c.surfaces[0]))).toEqual(SURFACE_CASES.map(() => true))
  })

  it('is red by the row’s name when a row is dropped or doubled', () => {
    const { drawn, pending, steps, unread } = UNFOLDED_ROWS.states
    const row = 'a rule nothing reads'
    expect(rowsMoved(ONE_CASE.states, { drawn, pending, steps, unread: unread.filter((r) => r !== row) }, 'states')).toEqual([`the row "${row}" is in no states run`])
    expect(rowsMoved(ONE_CASE.states, { drawn: [...drawn, row], pending, steps, unread }, 'states')).toEqual([`the row "${row}" is in 2 states runs (drawn, unread)`])
  })

  it('still reads every surface across its runs, and every light', () => {
    const read = new Set(SURFACE_CASES.flatMap((c) => surfacesOf({ surfaces: c.surfaces })))
    expect([...SURFACES].filter((s) => !read.has(s))).toEqual([])
    const lit = new Set(STATE_CASES.flatMap((c) => c.only))
    expect(LIGHT_NAMES.filter((l) => !lit.has(l))).toEqual([])
    // The run that names unread rules goes through the same five lights the one case did.
    expect([...STATE_CASES.find((c) => LIGHT_NAMES.every((l) => c.only?.includes(l))).only].sort()).toEqual([...LIGHT_NAMES].sort())
    expect(() => surfacesOf({ surfaces: ['raised', 'floor'] })).toThrow(/no such surface: floor/)
  })

  it('runs a case on a part the package has, and is red by the case’s name on any other', () => {
    const names = ['button', 'tabs']
    expect(partOf({ name: 'x' }, names)).toBe('button')
    expect(partOf({ name: 'x', part: 'tabs' }, names)).toBe('tabs')
    expect(() => partOf({ name: 'x', part: 'tab' }, names)).toThrow('the case "x" runs on the part "tab", which is not one; the parts are button, tabs (parts/)')
    expect(() => partOf({ name: 'x', part: undefined }, names)).toThrow('the case "x" runs on the part null, which is not one')
  })
})

describe('every selftest case', () => {
  const most = CASE_SHARE * CASE_SECONDS

  it(`runs under the one limit of ${CASE_SECONDS} s, its hosted reading under ${CASE_SHARE * 100}% of it`, () => {
    expect(caseLimitsWrong(CASES, CASE_READINGS)).toEqual([])
  })

  it('is red by its name when it carries a limit of its own, has no reading, or reads over the share', () => {
    const c = CASES.find((x) => !x.direct)
    const own = CASES.map((x) => (x === c ? { ...x, secs: 150 } : x))
    expect(caseLimitsWrong(own, CASE_READINGS)).toEqual([`the case "${c.name}" holds "secs", which the runner does not read; every case runs under the one limit of ${CASE_SECONDS} s (check/capacity.mjs), and none carries its own`])
    const unread = Object.fromEntries(Object.entries(CASE_READINGS).map(([k, r]) => [k, { ...r, cases: Object.fromEntries(Object.entries(r.cases).filter(([n]) => n !== c.name)) }]))
    expect(caseLimitsWrong(CASES, unread)).toEqual([`the case "${c.name}" has no hosted reading in check/case-readings.mjs`])
    const [key, r] = Object.entries(CASE_READINGS).find(([, x]) => c.name in x.cases)
    const slow = { ...CASE_READINGS, [key]: { ...r, cases: { ...r.cases, [c.name]: most } } }
    expect(caseLimitsWrong(CASES, slow)).toEqual([`the case "${c.name}" took ${most} s on CI's hosted runner (job ${r.job}), at or over 80% of the one limit of ${CASE_SECONDS} s (${most} s): unfold it into runs`])
    const gone = { ...CASE_READINGS, [key]: { ...r, cases: { ...r.cases, 'a case no one wrote': 1 } } }
    expect(caseLimitsWrong(CASES, gone)).toEqual(['check/case-readings.mjs reads a case the selftest does not have: "a case no one wrote"'])
  })
})
