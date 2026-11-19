import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { MATCH_MIN } from '../check/reading.mjs'
import { ladderClaim } from '../check/plants.mjs'

const readme = readFileSync(new URL('../README.md', import.meta.url), 'utf8').replace(/\s+/g, ' ')

describe("README.md's claim about a label", () => {
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

describe("README.md's list of what part.css may condition on", () => {
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
  it("makes the check's ceilings from its readings, under the check step's limit in js-tests.yml, and the README says so", async () => {
    const { STEP_MINUTES, PARTS_HELD, READINGS, HEADROOM, capacitySentence, ceilingFor } = await import('../check/capacity.mjs')
    const workflow = readFileSync(new URL('../../../../.github/workflows/js-tests.yml', import.meta.url), 'utf8')
    const step = workflow.slice(workflow.indexOf('name: "BarkUI showroom check (real keys in Chromium)"'))
    expect(step.match(/timeout-minutes: (\d+)/)[1]).toBe(String(STEP_MINUTES))
    // Every ceiling has room over its own reading, and every reading names where and at which commit it was read.
    for (const r of READINGS.check) {
      expect(r.where && r.commit && r.seconds > 0 && r.parts > 0).toBeTruthy()
      expect(ceilingFor(r.parts)).toBeGreaterThanOrEqual(HEADROOM * r.seconds)
    }
    expect(HEADROOM).toBeGreaterThan(1)
    // The ceiling of the most parts held stays under the step's limit; one part more would not.
    expect(PARTS_HELD).toBeGreaterThanOrEqual(1)
    expect(ceilingFor(PARTS_HELD)).toBeLessThan(STEP_MINUTES * 60)
    expect(ceilingFor(PARTS_HELD + 1)).toBeGreaterThanOrEqual(STEP_MINUTES * 60)
    expect(readme).toContain(capacitySentence())
  })

  it("makes the selftest's ceiling from its reading, at most its share of its step in js-tests.yml, and the README says so", async () => {
    const { SELFTEST_STEP_MINUTES, SELFTEST_CEILING, SELFTEST_MOST, READINGS, HEADROOM, selftestSentence } = await import('../check/capacity.mjs')
    const workflow = readFileSync(new URL('../../../../.github/workflows/js-tests.yml', import.meta.url), 'utf8')
    const step = workflow.slice(workflow.indexOf('name: "BarkUI showroom check selftest'))
    expect(step.match(/timeout-minutes: (\d+)/)[1]).toBe(String(SELFTEST_STEP_MINUTES))
    expect(READINGS.selftest.where && READINGS.selftest.commit).toBeTruthy()
    expect(SELFTEST_CEILING).toBeGreaterThanOrEqual(HEADROOM * READINGS.selftest.seconds)
    expect(SELFTEST_CEILING).toBeLessThanOrEqual(SELFTEST_MOST * SELFTEST_STEP_MINUTES * 60)
    expect(readme).toContain(selftestSentence())
  })

  it('a ceiling fails the run the moment it passes, and the environment can only lower it', () => {
    const at = new URL('../check/ceiling.mjs', import.meta.url).href
    const run = (env, ceiling) =>
      spawnSync(process.execPath, ['--input-type=module', '-e', `const { enforceCeiling } = await import(${JSON.stringify(at)}); enforceCeiling(${ceiling}, (s) => 'passed ' + s); await new Promise((r) => setTimeout(r, 1500)); console.log('ran on')`], { env: { ...process.env, ...env }, encoding: 'utf8' })
    const lowered = run({ BARKUI_CEILING_SECONDS: '0.2' }, 60)
    expect([lowered.status, lowered.stdout.trim()]).toEqual([1, 'passed 0.2'])
    const raised = run({ BARKUI_CEILING_SECONDS: '60' }, 0.2)
    expect([raised.status, raised.stdout.trim()]).toEqual([1, 'passed 0.2'])
  })
})
