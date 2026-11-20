import { describe, expect, it } from 'vitest'
import { pinStates } from '../build/showroom.mjs'
import { PINNED, resolve, selectorFindings, STATIC, statesOnSubject, strip, unpinned } from '../check/selectors.mjs'

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
    // A sample, not the judge (the pinned list below is): what a person changes waits until the check drives it.
    for (const p of ['focus', 'focus-within', 'placeholder-shown', 'user-invalid', 'enabled', 'open', 'muted', 'target-current', 'state']) expect(selectorFindings(`a:${p}`).length, p).toBe(1)
  })

  it('always allows only structure: the list is pinned whole, each name with why no click or key changes it', () => {
    const structure = {
      not: 'a negation of the selectors inside it, which are judged as any selector is',
      is: 'a group of the selectors inside it, which are judged as any selector is',
      where: 'a group like :is() with no weight, judged the same way',
      has: 'a relation to other elements, which are judged as any selector is',
      defined: 'a custom element is defined once its script registers it, as the page loads',
      'first-child': 'a place in the markup',
      'last-child': 'a place in the markup',
      'only-child': 'a place in the markup',
      'nth-child': 'a place in the markup',
      'nth-last-child': 'a place in the markup',
      'first-of-type': 'a place in the markup',
      'last-of-type': 'a place in the markup',
      'only-of-type': 'a place in the markup',
      'nth-of-type': 'a place in the markup',
      'nth-last-of-type': 'a place in the markup',
    }
    expect(STATIC).toEqual(Object.keys(structure))
    expect(PINNED.filter((p) => STATIC.includes(p))).toEqual([])
  })

  it('takes :checked as a pinned state, on the element a rule styles only', () => {
    for (const [sel, parent] of [['input[type="checkbox"]:checked', false], ['&:checked', false]]) expect(selectorFindings(sel, parent), sel).toEqual([])
    for (const sel of ['label:has(:checked)', 'input:checked + span', 'a:not(:checked)']) expect(selectorFindings(sel).length, sel).toBeGreaterThan(0)
    expect(strip('input:checked::before')).toEqual({ selector: 'input', states: ['checked'] })
  })

  it('makes a nested selector absolute and takes its states and pseudo-element out, for element.matches', () => {
    expect(resolve('&:hover > svg', '[data-slot="button"]')).toBe(':is([data-slot="button"]):hover > svg')
    expect(strip(':is(a):hover:not([t=":hover"])::before')).toEqual({ selector: ':is(a):not([t=":hover"])', states: ['hover'] })
    expect(strip(':active, b > ::after')).toEqual({ selector: '*, b > *', states: ['active'] })
  })

  it('pins a state whatever its case, and names one the pin did not reach', () => {
    expect(pinStates('a:HOVER { }')).toBe('a:is(:hover, [data-pin~="hover"]) { }')
    for (const p of PINNED) expect(unpinned(pinStates(`a:${p.toUpperCase()}`)), p).toEqual([])
    expect(unpinned('a:is(:hover, [data-pin~="hover"])')).toEqual([])
    expect(unpinned('a:hover')).toEqual([':hover'])
  })
})
