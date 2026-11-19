import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { MATCH_MIN } from '../check/reading.mjs'
import { ladderClaim } from '../check/selftest.mjs'

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
  it("keeps check/capacity.mjs to the check step's limit in js-tests.yml, and the README to its sentence", async () => {
    const { STEP_MINUTES, PARTS_HELD, capacitySentence } = await import('../check/capacity.mjs')
    const workflow = readFileSync(new URL('../../../../.github/workflows/js-tests.yml', import.meta.url), 'utf8')
    const step = workflow.slice(workflow.indexOf('name: "BarkUI showroom check (real keys in Chromium)"'))
    expect(step.match(/timeout-minutes: (\d+)/)[1]).toBe(String(STEP_MINUTES))
    expect(Number.isInteger(PARTS_HELD) && PARTS_HELD >= 1).toBe(true)
    expect(readme).toContain(capacitySentence())
  })

  it("keeps the selftest's measured time and step to its limit in js-tests.yml, and the README to its sentence", async () => {
    const { SELFTEST_STEP_MINUTES, SELFTEST_MEASURED, SELFTEST_PLANNED, selftestSentence } = await import('../check/capacity.mjs')
    const workflow = readFileSync(new URL('../../../../.github/workflows/js-tests.yml', import.meta.url), 'utf8')
    const step = workflow.slice(workflow.indexOf('name: "BarkUI showroom check selftest'))
    expect(step.match(/timeout-minutes: (\d+)/)[1]).toBe(String(SELFTEST_STEP_MINUTES))
    expect(SELFTEST_MEASURED).toBeGreaterThan(0)
    expect(SELFTEST_MEASURED).toBeLessThan(SELFTEST_PLANNED)
    expect(readme).toContain(selftestSentence())
  })
})
