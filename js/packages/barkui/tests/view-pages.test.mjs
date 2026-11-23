// The skins light's views on pages at once (check/view-pages.mjs): each view on one page, by one rule over the list,
// and a view on no page, on two, or off the list red by name.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { skinNames, tokensPath } from '../build/showroom.mjs'
import { spread, VIEW_PAGES, viewList, viewsRead } from '../check/view-pages.mjs'

const skins = skinNames(readFileSync(tokensPath, 'utf8'))
const views = viewList(skins)

describe('the views on pages at once', () => {
  it('reads every view of every skin in both schemes, each on one page', () => {
    expect(views.length).toBe(skins.length * 2)
    expect(VIEW_PAGES).toBe(2)
    const shares = spread(views)
    expect(shares.map((s) => s.length)).toEqual([skins.length, skins.length])
    expect(viewsRead(views, shares)).toEqual({ line: `views the skins light read: ${views.length} of ${views.length}; on two pages: 0; on none: 0`, fail: null })
    expect(viewsRead(views, spread(views, 1)).line).toBe(viewsRead(views, shares).line)
    expect(viewsRead(views, shares, 'the phone light').line).toBe(`views the phone light read: ${views.length} of ${views.length}; on two pages: 0; on none: 0`)
  })

  it('is red by name when a view is left out, read twice, or off the list', () => {
    const shares = spread(views)
    const dropped = [shares[0], shares[1].slice(1)]
    expect(viewsRead(views, dropped).fail).toBe(`the skins light's pages do not read each view once: views the skins light read: ${views.length - 1} of ${views.length}; on two pages: 0; on none: 1 (on none: ${views[1].skin} light)`)
    expect(viewsRead(views, [shares[0], [...shares[1], views[0]]]).fail).toMatch(/on two pages: 1; on none: 0 \(on two: \w+ light\)$/)
    expect(viewsRead(views, [shares[0], [...shares[1], { skin: 'x', scheme: 'light' }]]).fail).toMatch(/; off the list: 1$/)
    expect(viewsRead(views, [shares[0]]).fail).toMatch(new RegExp(`on none: ${skins.length} \\(on none: `))
  })
})
