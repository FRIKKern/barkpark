// The page one CI job reads (check/check.mjs runCheck, given `names`): each part it reads, with the stage that follows
// it on the page of every part, and no other stage; so the page holds at most twice the parts it reads.
import { describe, expect, it } from 'vitest'
import { groupsOf, pageNames, partNames, partsDir } from '../check/jobs.mjs'

describe("a job's page", () => {
  it('prints each part a job reads and the stage that follows each on the page of every part, at most twice the parts it reads', () => {
    const order = ['a', 'b', 'c', 'd', 'e', 'f', 'g']
    expect(pageNames(order, ['a', 'c'])).toEqual(['a', 'b', 'c', 'd'])
    expect(pageNames(order, ['b', 'c', 'g'])).toEqual(['b', 'c', 'd', 'g'])
    expect(pageNames(order, ['f'])).toEqual(['f', 'g'])
    for (let mask = 1; mask < 1 << order.length; mask++) {
      const names = order.filter((_, i) => mask & (1 << i))
      const page = pageNames(order, names)
      for (const n of names) {
        expect(page, `${names}`).toContain(n)
        const next = order[order.indexOf(n) + 1]
        if (next) expect(page[page.indexOf(n) + 1], `${names}: after ${n}`).toBe(next)
      }
      for (const n of page) expect(names.includes(n) || names.includes(order[order.indexOf(n) - 1]), `${names}: ${n}`).toBe(true)
      expect(page.length).toBeLessThanOrEqual(2 * names.length)
    }
    // And on this checkout's own split, in the order of the page of every part.
    const all = partNames(partsDir, {})
    for (const g of groupsOf(partsDir, {})) expect(pageNames(all, g.parts).length, `group ${g.group}`).toBeLessThanOrEqual(2 * g.parts.length)
  })
})
