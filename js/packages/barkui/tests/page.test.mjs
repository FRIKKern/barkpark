import { describe, expect, it } from 'vitest'
import { renderPage } from '../build/page.mjs'
import { SHEET_WAITS } from '../build/sheet-waits.mjs'

const part = { name: 'aa', hash: 'h1', example: '<p>x</p>', json: { family: 'f', element: 'ui-x', summary: 's' } }
const allOn = { pressed: { pass: true }, skins: { pass: true }, schemes: { pass: true }, phone: { pass: true }, noscript: { pass: true } }
const page = (run, extra = {}) =>
  renderPage({ parts: [part], skins: ['a', 'b'], foundation: 'f1', uiSdkVersion: '0', proof: { ranAt: '2026-01-01T00:00:00Z', browser: 'B', foundation: 'f1', parts: { aa: run }, ...extra } })
const lit = (html) => (html.match(/data-on="true"/g) ?? []).length

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

  it('prints the sheet wait from the measured number, and drops it when the sheet delivers', () => {
    const needs = SHEET_WAITS.controlEdge.needs
    const weak = page({ hash: 'h1', lights: allOn, measures: { controlEdge: { min: 1.01, max: 1.34 } } })
    expect(weak).toContain(`waiting on the sheet: control edge 1.01:1, needs ${needs}:1`)
    const strong = page({ hash: 'h1', lights: allOn, measures: { controlEdge: { min: needs + 0.2, max: 9 } } })
    expect(strong).not.toContain('waiting on the sheet')
  })

  it('counts the elements that carry no paint, from the proof', () => {
    const paintFree = [{ selector: '#aa-a', why: 'w' }, { selector: '#aa-b', why: 'w' }]
    expect(page({ hash: 'h1', lights: allOn, paintFree })).toContain('2 elements carry no paint')
    expect(page({ hash: 'h1', lights: allOn, paintFree: [] })).not.toContain('carry no paint')
  })
})
