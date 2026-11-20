import { describe, expect, it } from 'vitest'
import { pinStates } from '../build/showroom.mjs'
import { CHANGED_BY_A_PERSON, PINNED, resolve, selectorFindings, STATIC, statesOnSubject, strip, unpinned } from '../check/selectors.mjs'

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
    // What a person changes by clicking or typing waits until the check drives it as a pinned state.
    for (const p of CHANGED_BY_A_PERSON.filter((p) => !PINNED.includes(p) && p !== 'focus-visible')) expect(selectorFindings(`a:${p}`).length, p).toBe(1)
  })

  it('always allows no state a person changes by clicking or typing', () => {
    // Pinned whole: a name added here must be shown to be structure, not something a person changes.
    expect(STATIC).toEqual(['not', 'is', 'where', 'has', 'defined', 'first-child', 'last-child', 'only-child', 'nth-child', 'nth-last-child', 'first-of-type', 'last-of-type', 'only-of-type', 'nth-of-type', 'nth-last-of-type'])
    expect(STATIC.filter((p) => CHANGED_BY_A_PERSON.includes(p))).toEqual([])
    expect(PINNED.filter((p) => !CHANGED_BY_A_PERSON.includes(p))).toEqual([])
    for (const p of ['checked', 'placeholder-shown', 'user-invalid', 'focus-within', 'open', 'enabled', 'muted', 'target-current', 'state']) expect(CHANGED_BY_A_PERSON, p).toContain(p)
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
