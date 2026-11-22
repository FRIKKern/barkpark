// The lists of check/motion.mjs hold where they are used: docs/PARTS.md says where motion may be declared in the
// sentence made from PLACES, and every restyle call names one of CHANGES, each of which has a caller.
import { readdirSync, readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { CHANGES, MOTION_SENTENCE } from '../check/motion.mjs'

const DIR = new URL('../check/', import.meta.url)
const checker = () => readdirSync(DIR).filter((f) => f.endsWith('.mjs') && !/-cases\.mjs$|^selftest\.mjs$/.test(f))

describe('where motion may be declared', () => {
  it("is said in docs/PARTS.md in the sentence made from check/motion.mjs's PLACES", () => {
    const doc = readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8').replace(/\s+/g, ' ')
    expect(doc).toContain(MOTION_SENTENCE)
  })
})

describe("the checker's changes to a page's look", () => {
  it('each go through restyle under a name of CHANGES, and each name has a caller', () => {
    const callers = new Set()
    for (const f of checker()) {
      const text = readFileSync(new URL(f, DIR), 'utf8')
      for (const m of text.matchAll(/\brestyle\(\s*(['"`])((?:(?!\1).)*)\1/g)) callers.add(m[2])
    }
    const through = CHANGES.filter((c) => callers.has(c))
    console.log(`checker changes to a page's look: ${CHANGES.length}; through restyle: ${through.length}`)
    expect([...callers].filter((c) => !CHANGES.includes(c))).toEqual([])
    expect(through).toEqual(CHANGES)
  })
})
