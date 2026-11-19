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
