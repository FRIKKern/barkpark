import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { MATCH_MIN } from '../check/reading.mjs'
import { ladderClaim } from '../check/plants.mjs'

const readme = readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8').replace(/\s+/g, ' ')

describe("docs/PARTS.md's claim about a label", () => {
  it('states the limit the check holds a label to', () => {
    expect(readme).toContain(`A label must match at ${MATCH_MIN} or more`)
    expect(readme).toContain(`Under ${MATCH_MIN} (\`MATCH_MIN\``)
  })

  it('states the ladder in the one sentence the selftest holds to its measured steps', () => {
    const claim = ladderClaim()
    expect(claim).not.toBeNull()
    for (const kind of ['cut', 'ground', 'ink']) expect(claim.on[kind]).toBe(claim.first[kind] - 1)
    expect(readme).not.toMatch(/whole or partial/)
  })
})

describe("docs/PARTS.md's list of what part.css may condition on", () => {
  it('names every @media condition the parsed-sheet check allows, and the shared keyframes', async () => {
    const { KEYFRAMES, MEDIA } = await import('../build/vocabulary.mjs')
    const table = readme.slice(readme.indexOf('## What part.css may condition on'), readme.indexOf('## What the check proves about a label'))
    expect(table).toContain('@media (max-width: 600px)')
    expect(table).toContain('@media (prefers-reduced-motion: …)')
    expect(MEDIA).toEqual(['(max-width: 600px)', '(prefers-reduced-motion: reduce)', '(prefers-reduced-motion: no-preference)'])
    for (const k of KEYFRAMES) expect(readme).toContain(`\`${k}\``)
  })
})

describe('how many parts the check holds', () => {
  it("makes the ceilings from the readings, holds them under the steps' limits in barkui.yml, and docs/PARTS.md's passage word for word", async () => {
    const c = await import('../check/capacity.mjs')
    const p = c.plan()
    const workflow = readFileSync(new URL('../../../../.github/workflows/barkui.yml', import.meta.url), 'utf8')
    const minutes = (name) => workflow.slice(workflow.indexOf(name)).match(/timeout-minutes: (\d+)/)[1]
    expect(minutes('name: "Check this group\'s parts (real keys in Chromium)"')).toBe(String(p.STEP_MINUTES))
    // Each selftest job's step has the one limit, and each job has its own reading, by the keys check/jobs.mjs names.
    const { SELFTEST_JOBS } = await import('../check/jobs.mjs')
    const steps = workflow.split('name: "Each planted break turns its light off"').slice(1)
    expect(steps.length).toBe(SELFTEST_JOBS.length)
    for (const step of steps) expect(step.match(/timeout-minutes: (\d+)/)[1]).toBe(String(p.SELFTEST_STEP_MINUTES))
    expect(Object.keys(p.READINGS.selftest).sort()).toEqual(SELFTEST_JOBS.map((j) => j.key).sort())
    // Every reading names its run and commit; every ceiling has room over its own reading.
    for (const r of [...p.READINGS.check, ...Object.values(p.READINGS.selftest)]) expect(r.run > 0 && /^[0-9a-f]{10}$/.test(r.commit) && r.seconds > 0).toBe(true)
    for (const r of p.READINGS.check) expect(Number.isInteger(r.folder) && r.folder >= r.parts).toBe(true)
    expect(p.HEADROOM).toBeGreaterThan(1)
    for (const r of p.READINGS.check) expect(p.ceilingFor(r.parts)).toBeGreaterThanOrEqual(p.HEADROOM * r.seconds)
    for (const [k, r] of Object.entries(p.READINGS.selftest)) expect(p.SELFTEST_CEILINGS[k], k).toBeGreaterThanOrEqual(p.HEADROOM * r.seconds)
    // The ceiling of the most parts held stays under the check step; one part more would not.
    expect(p.PER_JOB).toBeGreaterThanOrEqual(1)
    expect(p.ceilingFor(p.PER_JOB)).toBeLessThan(p.STEP_MINUTES * 60)
    expect(p.ceilingFor(p.PER_JOB + 1)).toBeGreaterThanOrEqual(p.STEP_MINUTES * 60)
    for (const [k, c] of Object.entries(p.SELFTEST_CEILINGS)) expect(c, k).toBeLessThanOrEqual(p.SELFTEST_MOST * p.SELFTEST_STEP_MINUTES * 60)
    // The passage between the marks is exactly what the numbers make, and any other input makes another.
    const raw = readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8')
    const [a, b] = c.MARKS.map((m) => raw.indexOf(m))
    const passage = raw.slice(a + c.MARKS[0].length, b).trim()
    expect(a >= 0 && b > a).toBe(true)
    expect(passage).toBe(c.capacityPassage())
    for (const change of [{ HEADROOM: 1.4 }, { SELFTEST_MOST: 0.75 }, { STEP_MINUTES: 20 }, { AT_ONCE: 2 }, { READINGS: { ...c.INPUT.READINGS, selftest: { ...c.INPUT.READINGS.selftest, views: { ...c.INPUT.READINGS.selftest.views, seconds: 300 } } } }, { READINGS: { ...c.INPUT.READINGS, selftest: { ...c.INPUT.READINGS.selftest, rest: { ...c.INPUT.READINGS.selftest.rest, seconds: 100 } } } }, { READINGS: { ...c.INPUT.READINGS, check: c.INPUT.READINGS.check.map((r) => ({ ...r, folder: r.folder + 12 })) } }])
      expect(c.capacityPassage(c.plan({ ...c.INPUT, ...change })), JSON.stringify(change)).not.toBe(passage)
  })

  it('a ceiling fails the run the moment it passes, and the environment can only lower it', () => {
    const at = new URL('../check/ceiling.mjs', import.meta.url).href
    const run = (env, ceiling) =>
      spawnSync(process.execPath, ['--input-type=module', '-e', `const { enforceCeiling } = await import(${JSON.stringify(at)}); enforceCeiling(${ceiling}, (s) => 'passed ' + s); await new Promise((r) => setTimeout(r, 1500)); console.log('ran on')`], { env: { ...process.env, ...env }, encoding: 'utf8' })
    for (const [env, ceiling, said] of [['0', 60, 'passed 0'], ['0.2', 60, 'passed 0.2'], ['60', 0.2, 'passed 0.2'], ['', 0.2, 'passed 0.2'], ['text', 0.2, 'passed 0.2'], ['-5', 0.2, 'passed 0.2']]) {
      const r = run({ BARKUI_CEILING_SECONDS: env }, ceiling)
      expect([r.status, r.stdout.trim()], `${env} against ${ceiling}`).toEqual([1, said])
    }
  })
})
