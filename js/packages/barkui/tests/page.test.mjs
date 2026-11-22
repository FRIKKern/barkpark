import { describe, expect, it } from 'vitest'
import { renderPage, SURFACES } from '../build/page.mjs'
import { SHEET_WAITS, waitsFor } from '../build/sheet-waits.mjs'

const part = { name: 'aa', hash: 'h1', example: '<p>x</p>', json: { family: 'f', element: 'ui-x', summary: 's' } }
const allOn = { pressed: { pass: true }, skins: { pass: true }, schemes: { pass: true }, phone: { pass: true }, noscript: { pass: true } }
const page = (run, extra = {}) =>
  renderPage({ parts: [part], skins: ['a', 'b'], foundation: 'f1', uiSdkVersion: '0', proof: { ranAt: '2026-01-01T00:00:00Z', browser: 'B', foundation: 'f1', parts: { aa: run }, ...extra } })
const lit = (html) => (html.match(/data-on="true"/g) ?? []).length

describe('renderPage notCovered', () => {
  it('prints what a part does not cover in one place under its summary, and nothing when it covers all', () => {
    const list = [{ name: 'ui-x-indicator', why: 'Not on the stage <yet>.' }]
    const html = renderPage({ parts: [{ ...part, json: { ...part.json, notCovered: list } }], skins: ['a'], foundation: 'f1', uiSdkVersion: '0', proof: null })
    expect(html).toContain('<p class="sr-summary">s</p>\n    <div class="sr-not-covered"><p>Not covered</p><ul><li><code>ui-x-indicator</code>: Not on the stage &lt;yet&gt;.</li></ul></div>')
    expect(page({ hash: 'h1', lights: allOn })).not.toContain('sr-not-covered')
  })
})

describe('renderPage proof lights', () => {
  it('lights what a passing run proved', () => {
    expect(lit(page({ hash: 'h1', lights: allOn }))).toBe(5)
  })

  it('lights nothing for a part whose run failed, and says so', () => {
    const html = page({ hash: 'h1', lights: allOn, failed: 'page error: boom' })
    expect(lit(html)).toBe(0)
    expect(html).toContain('The last check run failed')
  })

  it('lights nothing when the run logged page errors', () => {
    expect(lit(page({ hash: 'h1', lights: allOn }, { errors: ['console: boom'] }))).toBe(0)
  })

  it('prints each wait on the sheet the run measured short, bound to its view and tokens, and drops it when the sheet delivers', () => {
    const w = { ...SHEET_WAITS.find((x) => x.skin === 'fjord' && x.scheme === 'light') }
    const weak = page({ hash: 'h1', lights: allOn, measures: { waits: [{ ...w, now: 3.75 }] } })
    expect(weak).toContain(`waiting on the sheet: --ui-muted-foreground on --ui-background, fjord light on primary, 3.75:1, needs 4.5:1, until the sheet makes muted text on the primary surface readable in every skin`)
    expect(weak).toContain(`data-task="${w.task}"`)
    const strong = page({ hash: 'h1', lights: allOn, measures: { waits: [{ ...w, now: 4.6 }] } })
    expect(strong).not.toContain('waiting on the sheet')
  })

  it('counts the elements that carry no paint, from the proof', () => {
    const paintFree = [{ selector: '#aa-a', why: 'w' }, { selector: '#aa-b', why: 'w' }]
    expect(page({ hash: 'h1', lights: allOn, paintFree })).toContain('2 elements carry no paint')
    expect(page({ hash: 'h1', lights: allOn, paintFree: [] })).not.toContain('carry no paint')
  })

  it('says which surfaces the lights were proved on, so any other can show them as not proved', () => {
    const on = (surfaces) => page({ hash: 'h1', lights: Object.fromEntries(Object.entries(allOn).map(([k, l]) => [k, { ...l, surfaces }])) })
    expect(on(['base'])).toContain('data-proved-on="base"')
    expect(on(['base'])).toMatch(/proved on base</)
    expect(on(SURFACES)).toContain(`data-proved-on="${SURFACES.join(' ')}"`)
    expect(on(SURFACES)).toMatch(/proved on every surface</)
  })

  it('binds every wait to one skin, scheme, surface and token pair, with the number it measured', () => {
    for (const w of SHEET_WAITS) {
      expect(Object.keys(w).sort()).toEqual(['ground', 'measured', 'needs', 'scheme', 'skin', 'surface', 'task', 'text', 'until'])
      expect(SURFACES).toContain(w.surface)
      expect(w.measured).toBeLessThan(w.needs)
    }
    expect(waitsFor('fjord', 'light', 'primary')).toHaveLength(1)
    expect(waitsFor('fjord', 'light', 'raised')).toEqual([])
    expect(waitsFor('fjord', 'dark', 'primary')).toEqual([])
  })

  it('prints the control boundary it proved, and names the controls that are text-only', () => {
    const html = page({
      hash: 'h1',
      lights: allOn,
      measures: { boundary: { min: 4.61, max: 9.2, at: 'button#aa-s "Save draft"' }, 'boundary:primary': { min: 3.04, max: 8.9 } },
      textOnly: [{ selector: '[data-variant="ghost"]', controls: ['Cancel', 'Rest'] }],
    })
    expect(html).toContain('control boundary 3.04:1 or more on every control on all 2 surfaces, needs 3:1')
    expect(html).toContain('text-only, no boundary, label held to text rules: Cancel, Rest')
  })
})
