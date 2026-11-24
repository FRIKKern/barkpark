import { describe, expect, it } from 'vitest'
import { hideOthers } from '../check/part-page.mjs'

const section = (n) => `<section class="sr-part" id="part-${n}" aria-labelledby="part-${n}-title"><div class="sr-stage" data-part="${n}"></div></section>`
const page = (names) => `<main>${names.map(section).join('\n')}</main>`
const hidden = (html) => [...html.matchAll(/id="part-([\w-]+)" hidden aria-labelledby/g)].map((m) => m[1])

describe('the page a part is read on', () => {
  it('hides the stage of every part but its own and the one that follows it, and prints every stage', () => {
    const order = ['button', 'checkbox', 'dialog', 'menu', 'radio']
    expect(hidden(hideOthers(page(order), order, 'dialog'))).toEqual(['button', 'checkbox', 'radio'])
    expect(hidden(hideOthers(page(order), order, 'button'))).toEqual(['dialog', 'menu', 'radio'])
    expect(hidden(hideOthers(page(order), order, 'radio'))).toEqual(['button', 'checkbox', 'dialog', 'menu'])
    for (const n of order) expect(hideOthers(page(order), order, 'menu')).toContain(`data-part="${n}"`)
  })

  it('refuses a part the page does not print, and a stage the page does not print exactly once', () => {
    expect(() => hideOthers(page(['button']), ['button'], 'menu')).toThrow('the page prints no stage of menu')
    expect(() => hideOthers(page(['button']), ['button', 'menu'], 'button')).toThrow('the page prints the stage of menu 0 times, not once')
    expect(() => hideOthers(page(['button', 'button']), ['button'], 'button')).toThrow('the page prints the stage of button 2 times, not once')
  })
})
