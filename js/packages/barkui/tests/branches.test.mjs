import { describe, expect, it } from 'vitest'
import { ruleEntries } from '../check/cssom.mjs'
import { unread } from '../check/coverage.mjs'
import { choiceLists, splitList } from '../check/selectors.mjs'
import { textArms } from '../check/sheet-text.mjs'

// Coverage reads a rule branch by branch (docs/PARTS.md "Read"): a branch is one selector of a rule's own list, a
// nested rule's crossed with each of its parent's. A list inside :is(), :where() or :has() would be a branch in
// hiding, so part.css may not hold one.
describe('every branch of a selector list is read on its own', () => {
  it('splits a list at its own commas only: :not(a, b) and [x="a,b"] stay one branch', () => {
    expect(splitList('a, b:not(c, d), [x="e,f"]')).toEqual(['a', 'b:not(c, d)', '[x="e,f"]'])
  })

  it('crosses a nested rule with each branch of its parent', () => {
    const rules = [
      { text: '[data-a], [data-b]', parent: -1, decls: false, media: [] },
      { text: '& x, & y', parent: 0, decls: true, media: [] },
    ]
    const [e] = ruleEntries(rules, rules.map((r) => r.text))
    expect(e.branches.map((b) => b.label)).toEqual([':is([data-a]) x', ':is([data-a]) y', ':is([data-b]) x', ':is([data-b]) y'])
  })

  it('names a branch no reading saw, beside one that was read', () => {
    const entries = [{ label: 'a, b', branches: [{ label: 'a' }, { label: 'b' }] }]
    const ctx = { entries, judged: new Set([0 * 1e5 + 3]), branchesRead: new Set(['0.0']), pairs: [] }
    expect(unread(ctx)).toEqual(['a branch nothing read: b, of a, b, applies to nothing in the stage at any moment the lights read'])
  })

  it('refuses a list inside :is(), :where() or :has() from the text, and lets :not() and one arm through', () => {
    const one = (prelude) => textArms([{ prelude, body: '', blocks: [] }])
    for (const sel of ['&:is([data-a], [data-b])', ':where(ui-button, ui-link) > svg', 'ui-row:has([data-a], [data-b])'])
      expect(one(sel).found).toEqual([expect.stringMatching(/holds a list of 2; coverage reads a rule branch by branch/)])
    for (const sel of ['&:not([data-a], [data-b])', '&:is([data-a])', '[x=":is(a, b)"]']) expect(one(sel).found).toEqual([])
    expect(choiceLists('a:is(b, :where(c, d))')).toEqual([{ name: 'where', arms: ['c', 'd'] }, { name: 'is', arms: ['b', ':where(c, d)'] }])
  })

  it("gives the browser each arm the text writes, the rule's own and the one inside :is() and :where(), but not :has()'s", () => {
    const [b] = textArms([{ prelude: 'a, b:is(:x), c:where(d) > e:has(> f)', body: '', blocks: [{ prelude: '&:is(:y)', body: '', blocks: [] }] }]).written
    expect(b.arms).toEqual(['a', 'b:is(:x)', 'c:where(d) > e:has(> f)', ':x', 'd'])
    expect(b.blocks[0].arms).toEqual(['&:is(:y)', ':y'])
    expect(b.within).toEqual([{ name: 'is', arm: ':x' }, { name: 'where', arm: 'd' }])
    expect(b.blocks[0].within).toEqual([{ name: 'is', arm: ':y' }])
    expect(textArms([{ prelude: '@media (max-width: 600px)', body: '', blocks: [] }]).written[0].arms).toEqual([])
  })
})
