// The lists of check/motion.mjs hold where they are used: docs/PARTS.md says where motion may be declared in the
// sentence made from PLACES, and every restyle call names one of CHANGES, each of which has a caller.
import { readdirSync, readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { MOTION_ONLY } from '../build/vocabulary.mjs'
import { ACTS, CHANGES, LISTS, MOTION, MOTION_SENTENCE, motionRead } from '../check/motion.mjs'

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

  it("are counted with the checker's acts, each made with the option that leaves the page at rest, and an act without it is red by name", () => {
    const at = Object.fromEntries(Object.keys(ACTS).map((k) => [k, 0]))
    const wrong = []
    for (const f of checker().filter((f) => f !== 'motion.mjs')) {
      const text = readFileSync(new URL(f, DIR), 'utf8')
      const line = (i) => text.slice(0, i).split('\n').length
      for (const [k, { call, holds, through }] of Object.entries(ACTS)) {
        for (const m of through === f ? [] : text.matchAll(call)) {
          at[k]++
          if (holds && !holds.test(m[1])) wrong.push(`check/${f}:${line(m.index)}: ${k} without its option (check/motion.mjs ACTS)`)
        }
      }
    }
    console.log(`checker acts on a page: ${Object.values(at).filter(Boolean).length} kinds (${Object.entries(at).filter(([, n]) => n).map(([k, n]) => `${k} at ${n} places`).join(', ')}), each leaving the page at rest before the next read`)
    expect(wrong).toEqual([])
    expect(at['focus moved']).toBeGreaterThan(0)
    expect(at['a box scrolled into view']).toBeGreaterThan(0)
    expect(at['a key or the pointer used']).toBeGreaterThan(0)
  })
})

describe('the motion reader', () => {
  it('reads every motion property of the vocabulary, each under a rule of its own kind', () => {
    const vocabulary = [...MOTION_ONLY]
    const read = Object.keys(LISTS.motion)
    console.log(`motion properties in the vocabulary: ${vocabulary.length}; read by the motion reader: ${read.length}`)
    expect(read).toEqual(vocabulary)
    expect(MOTION.unread).toEqual([])
  })

  it('is red by name for a motion property it has no rule for', () => {
    expect(motionRead(['transition-duration', 'view-transition-name']).unread).toEqual([
      'the motion property view-transition-name (build/vocabulary.mjs MOTION) has no rule in the motion reader (check/motion.mjs MOTION_RULES)',
    ])
  })
})
