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
