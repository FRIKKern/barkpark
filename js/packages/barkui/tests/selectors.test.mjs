import { describe, expect, it } from 'vitest'
import { pinStates } from '../build/showroom.mjs'
import { selectorFindings, statesOnSubject, unpinned } from '../check/selectors.mjs'

// Inputs as the browser hands them back (selectorText): lowercase, `& ` before a nested descendant.
describe('a pinned state may stand only on the element a rule styles', () => {
  it('allows a state on the styled element, through & from its parent too', () => {
    for (const [sel, parent] of [['[data-slot="button"]:hover:not([data-disabled])', false], ['&:active:not([data-disabled], [data-pending])', false], ['&[data-size="sm"]', true], ['& > svg', false]])
      expect(selectorFindings(sel, parent)).toEqual([])
    expect(statesOnSubject('&:hover')).toBe(true)
  })

  it('refuses it on a host, ancestor or sibling, inside another pseudo-class, or above a nested rule', () => {
    for (const [sel, parent] of [['ui-button:hover > [data-slot="button"]', false], ['a:hover + b', false], ['a:has(:hover)', false], ['a:not(b:active)', false], ['& svg', true], ['& + b', true]])
      expect(selectorFindings(sel, parent).length, sel).toBeGreaterThan(0)
  })

  it('lists the pseudo-classes and pseudo-elements it allows, and refuses the rest', () => {
    expect(selectorFindings('a:target')[0]).toMatch(/:target is not a pseudo-class/)
    expect(selectorFindings('a::selection')[0]).toMatch(/::selection is not a pseudo-element/)
    expect(selectorFindings('a[title=":target"]::before')).toEqual([])
  })

  it('pins a state whatever its case, and names one the pin did not reach', () => {
    expect(pinStates('a:HOVER { }')).toBe('a:is(:hover, [data-pin~="hover"]) { }')
    expect(unpinned('a:is(:hover, [data-pin~="hover"])')).toEqual([])
    expect(unpinned('a:hover')).toEqual([':hover'])
  })
})
